// uhp-server：把多个 harness 统一成一个 UHP 端点。
//
// 用法：uhp-server [--config <path>] | --help | --version
// 配置见 config/uhp-server.example.toml。
package uhp_server

import std.collection.{ArrayList, HashMap}
import std.env.getCommandLine
import stdx.net.http.*
import uhp.server.*
import uhp.types.base.*

const UHP_SERVER_VERSION = "0.1.0"

func usage(): Unit {
    println("uhp-server " + UHP_SERVER_VERSION)
    println("用法：uhp-server [--config <配置文件>]")
    println("  --config, -c   配置文件路径（默认 uhp-server.toml）")
    println("  --help, -h     显示帮助")
    println("  --version, -V  显示版本")
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
            println("uhp-server " + UHP_SERVER_VERSION)
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
    println("uhp-server " + UHP_SERVER_VERSION + " 监听 http://" + cfg.server.bind + ":" + server.port.toString())
    println("  harnesses: " + names)
    server.serve()
    return 0
}
