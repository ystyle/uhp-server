// P1-c 收尾的两条：产物字节跨进程、在跑回合的崩溃感知。
package uhp_server

import std.collection.{ArrayList, HashMap}
import std.unittest.*
import std.unittest.testmacro.*
import stdx.net.http.*
import uhp.client.*
import uhp.server.*
import uhp.transport.*
import uhp.types.base.*
import uhp.types.generated.*
import uhp.types.handwritten.*
import uhp_acp.nowMillis

// 起一套 server + client（三条插件测试共用同一套壳）
class PluginBox {
    public let engine: Engine
    public let server: Server
    public let client: UhpClient
    public init(cfg: ServerConfig) {
        this.engine = Engine(buildHarnesses(cfg), cls: ConformanceClass.Full)
        let tokens = HashMap<String, String>()
        tokens["t"] = "alice"
        let uhpServer = UhpHttpServer(this.engine, Authenticator(tokens))
        this.server = ServerBuilder().addr("127.0.0.1").port(0)
            .distributor(uhpServer.distributor()).build()
        let s = this.server
        spawn {
            s.serve()
        }
        var bound: UInt16 = 0
        for (_ in 0..500) {
            bound = this.server.port
            if (bound != 0) {
                break
            }
            sleep(Duration.millisecond * 10)
        }
        let url = "http://127.0.0.1:" + bound.toString()
        this.client = UhpClient(url, "t", StdHttpTransport(url))
        let _ = this.client.discover()
    }
    public func close(): Unit {
        this.engine.close()
        this.server.close()
    }
}

func isolatedSpec(kind: String, pluginBin: String): HarnessSpec {
    let spec = HarnessSpec()
    spec.id = "iso"
    spec.kind = kind
    spec.isolate = true
    spec.plugin_path = pluginBin
    return spec
}

@Test
func plugin_carries_artifact_bytes(): Unit {
    let pluginBin = pluginBinPath()
    if (!readableFile(pluginBin)) {
        @Expect(true, true)
        return
    }
    let spec = isolatedSpec("scripted", pluginBin)
    spec.reply = "hello artifact"
    spec.file = "note.txt"
    let cfg = ServerConfig()
    cfg.harnesses.add(spec)
    let box = PluginBox(cfg)
    try {
        let resp = box.client.createTaskWithInput("make a file", harnessId: Some("iso"))
        @Expect(resp.status, "completed")
        let sid = match (resp.metadata) {
            case Some(m) => m.session_id ?? ""
            case None => ""
        }
        let files = box.client.sessionFiles(sid)
        @Expect(files.size, 1)
        let bytes = box.client.downloadFile(files[0].container_id ?? "", files[0].id)
        // 产物内容必须原样过境：插件里产生的字节 == 客户端下载到的字节
        @Expect(String.fromUtf8(bytes), "hello artifact")
    } finally {
        box.close()
    }
}

@Test
func plugin_crash_fails_in_flight_turn_fast(): Unit {
    let pluginBin = pluginBinPath()
    if (!readableFile(pluginBin)) {
        @Expect(true, true)
        return
    }
    let cfg = ServerConfig()
    cfg.harnesses.add(isolatedSpec("crash", pluginBin))
    let box = PluginBox(cfg)
    try {
        let started = nowMillis()
        let resp = box.client.createTaskWithInput("crash please", harnessId: Some("iso"))
        let elapsed = nowMillis() - started
        // 插件进程退出后回合应立刻失败；干等超时是 600s，这里给 60s 的余量足够区分两种行为
        @Expect(elapsed < 60000, true)
        @Expect(resp.status, "failed")
        match (resp.error) {
            case Some(e) => @Expect(e.code, "harness_error")
            case None => @Expect(false, true)
        }
    } finally {
        box.close()
    }
}
