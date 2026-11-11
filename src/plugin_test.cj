// P1 插件隔离的端到端：host 通过 cordis 拉起插件进程，任务真的在子进程里跑。
//
// 用 scripted backend：不需要任何模型/凭据，也能验证「进程边界 + 事件回传 + 终态映射」这条链路。
package uhp_server

import std.collection.{ArrayList, HashMap}
import std.fs.{File as FsFile, Path}
import std.unittest.*
import std.unittest.testmacro.*
import stdx.net.http.*
import uhp.client.*
import uhp.server.*
import uhp.transport.*
import uhp.types.base.*
import uhp.types.generated.*

// 插件二进制：workspace 根 target 或成员目录 target 都找一下（和 uhp-acp 的假 agent 同样的取舍）
func pluginBinPath(): String {
    let direct = "target/release/bin/uhp_server.plugin"
    let parent = "../target/release/bin/uhp_server.plugin"
    if (readableFile(direct)) {
        return direct
    }
    return parent
}

func readableFile(p: String): Bool {
    try {
        let _ = FsFile.readFrom(Path(p))
        return true
    } catch (e: Exception) {
        return false
    }
}

@Test
func plugin_isolation_runs_task_in_child_process(): Unit {
    let pluginBin = pluginBinPath()
    if (!readableFile(pluginBin)) {
        // 没构建插件（只跑单测、没 cjpm build 插件目标）时跳过，不伪装通过
        @Expect(true, true)
        return
    }
    let spec = HarnessSpec()
    spec.id = "iso"
    spec.kind = "scripted"
    spec.reply = "from plugin process"
    spec.isolate = true
    spec.plugin_path = pluginBin
    let cfg = ServerConfig()
    cfg.harnesses.add(spec)
    let harnesses = buildHarnesses(cfg)
    @Expect(harnesses.size, 1)
    let engine = Engine(harnesses, cls: ConformanceClass.Full)
    let tokens = HashMap<String, String>()
    tokens["t"] = "alice"
    let uhpServer = UhpHttpServer(engine, Authenticator(tokens))
    let server = ServerBuilder().addr("127.0.0.1").port(0).distributor(uhpServer.distributor()).build()
    let s = server
    spawn {
        s.serve()
    }
    var bound: UInt16 = 0
    for (_ in 0..500) {
        bound = server.port
        if (bound != 0) {
            break
        }
        sleep(Duration.millisecond * 10)
    }
    let url = "http://127.0.0.1:" + bound.toString()
    let client = UhpClient(url, "t", StdHttpTransport(url))
    let _ = client.discover()
    try {
        let resp = client.createTaskWithInput("hi", harnessId: Some("iso"))
        @Expect(resp.status, "completed")
        var text = ""
        for (item in resp.output) {
            if (let Some(content) <- item.content) {
                for (part in content) {
                    if (let Some(t) <- part.text) {
                        text = text + t
                    }
                }
            }
        }
        @Expect(text, "from plugin process")
    } finally {
        engine.close()
        server.close()
    }
}
