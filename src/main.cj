// uhp-server：把多个 harness 统一成一个 UHP 端点。
//
// 用法：uhp-server [--config <path>] | --help | --version
// 配置见 config/uhp-server.example.toml。
package uhp_server

import std.collection.{ArrayList, HashMap}
import std.env.{atExit, getCommandLine, getStdOut}
import stdx.net.http.*
import uhp.server.*
import uhp.types.base.*

const UHP_SERVER_VERSION = "0.1.3"

// 启动日志必须立刻可见：stdout 被重定向到文件/管道时（Docker、systemd、nohup）是块缓冲，
// 不显式 flush 的话进程被 SIGKILL 时日志全丢——运维只能看到「服务没反应」。
func info(msg: String): Unit {
    let out = getStdOut()
    out.write(msg + "\n")
    out.flush()
}

func usage(): Unit {
    info("uhp-server " + UHP_SERVER_VERSION)
    info("用法：uhp-server [--config <配置文件>]")
    info("  --config, -c   配置文件路径（默认 uhp-server.toml）")
    info("  --help, -h     显示帮助")
    info("  --version, -V  显示版本")
}

func fail(msg: String): Int64 {
    eprintln("uhp-server: " + msg)
    return 2
}

main(): Int64 {
    let argv = getCommandLine()
    var configPath = "uhp-server.toml"
    var i: Int64 = 1
    while (i < argv.size) {
        let a = argv[i]
        if (a == "--help" || a == "-h") {
            usage()
            return 0
        } else if (a == "--version" || a == "-V") {
            info("uhp-server " + UHP_SERVER_VERSION)
            return 0
        } else if (a == "--config" || a == "-c") {
            i = i + 1
            if (i >= argv.size) {
                return fail("--config 需要一个参数")
            }
            configPath = argv[i]
        } else {
            usage()
            return fail("未知参数：" + a)
        }
        i = i + 1
    }

    let cfg = try {
        loadConfig(configPath)
    } catch (e: ServerConfigError) {
        return fail("配置错误：" + e.message + "（文件：" + configPath + "）")
    } catch (e: Exception) {
        return fail("读配置失败：" + e.message + "（文件：" + configPath + "）")
    }

    if (cfg.tokens.size == 0) {
        return fail("至少要配一个 [[tokens]]（客户端用 Bearer token 访问）")
    }
    let tokens = HashMap<String, String>()
    for (t in cfg.tokens) {
        if (t.token.size == 0 || t.principal.size == 0) {
            return fail("[[tokens]] 需要同时有 token 与 principal")
        }
        tokens[t.token] = t.principal
    }

    let harnesses = try {
        buildHarnesses(cfg)
    } catch (e: ServerConfigError) {
        return fail("harness 配置错误：" + e.message)
    }
    var names = ""
    for (h in harnesses) {
        if (names.size > 0) { names = names + ", " }
        names = names + h.id
    }

    let engine = Engine(harnesses, cls: ConformanceClass.Full)
    let uhp = UhpHttpServer(engine, Authenticator(tokens))
    let server = try {
        ServerBuilder()
            .addr(cfg.server.bind)
            .port(UInt16(cfg.server.port))
            .distributor(uhp.distributor())
            .build()
    } catch (e: Exception) {
        return fail("监听 " + cfg.server.bind + ":" + cfg.server.port.toString() + " 失败：" + e.message)
    }
    info("uhp-server " + UHP_SERVER_VERSION + " 监听 http://" + cfg.server.bind + ":" + server.port.toString())
    info("  harnesses: " + names)
    if (cfg.server.session_ttl_seconds > 0) {
        info("  会话 TTL：" + cfg.server.session_ttl_seconds.toString() + " 秒（空闲即回收）")
    }
    startSessionReaper(engine, cfg.server.session_ttl_seconds)
    // 优雅退出：SIGTERM / SIGINT → 停 HTTP（serve 返回）→ 回收 driver（关 agent 子进程/插件进程）
    // 没有这个处理器时，容器里 PID 1 会忽略 SIGTERM（docker stop 每次等满 10s 宽限后被 SIGKILL）
    // 正常退出路径（serve() 返回 / 别处调 exit）兜底回收；信号路径走下面的优雅收尾。
    // engine.close() 幂等，重复调用无害。
    atExit({ => engine.close() })
    let _shutdown = installGracefulShutdown({ =>
        info("收到退出信号，开始收尾…")
        try {
            server.close()
        } catch (e: Exception) {
            ()
        }
        engine.close()
        info("收尾完成")
    })
    server.serve()
    // serve() 正常返回 = 服务已经关了：把 driver 持有的子进程/连接一起收掉。
    // 注意：Cangjie 没有信号注册接口，SIGTERM 会直接结束进程；此时靠 ACP agent 的 stdin
    // 收到 EOF 自行退出兜底（实测 dsh / pi-acp / opencode acp 都会）。
    engine.close()
    return 0
}

// 会话 TTL 驱逐：按固定间隔扫一遍空闲会话。idleSeconds <= 0 = 关闭。
//
// 为什么要做：协议的会话是服务端内存状态，没有删除端点；长跑服务不回收的话，
// 会话记录与 agent 侧作用域会一直涨（每个会话在 agent 里都是一份上下文）。
func startSessionReaper(engine: Engine, idleSeconds: Int64): Unit {
    if (idleSeconds <= 0) {
        return
    }
    let tick = if (idleSeconds < 30) { idleSeconds } else { 30 }
    spawn {
        while (true) {
            sleep(Duration.second * tick)
            let n = engine.reapIdleSessions(idleSeconds)
            if (n > 0) {
                info("会话 TTL：回收 " + n.toString() + " 个空闲会话")
            }
        }
    }
}
