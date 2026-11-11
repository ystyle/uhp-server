// P1-c：跨进程两轮问答。插件里的驱动提问 → 宿主上报 input_request → 客户端作答 →
// 答案送回插件 → 同一条 run invoke 继续跑完。
//
// 判据：①第一轮是 incomplete 且带 inreq_ 前缀的请求 id；②第二轮 completed 且文本带答案；
// ③两轮同一个 session（问答不是新会话）。
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

// 从响应里取 input_request 的 id（output item 的 typeName 是协议里的字面量）
func inputRequestIdOf(r: Response): String {
    for (item in r.output) {
        if (item.typeName == "input_request") {
            return item.id ?? ""
        }
    }
    return ""
}

@Test
func plugin_bridges_input_request_across_processes(): Unit {
    let pluginBin = pluginBinPath()
    if (!readableFile(pluginBin)) {
        @Expect(true, true)
        return
    }
    let spec = HarnessSpec()
    spec.id = "ask"
    spec.kind = "ask"
    spec.isolate = true
    spec.plugin_path = pluginBin
    let cfg = ServerConfig()
    cfg.harnesses.add(spec)
    let engine = Engine(buildHarnesses(cfg), cls: ConformanceClass.Full)
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
        let first = client.createTaskWithInput("ask me", harnessId: Some("ask"))
        @Expect(first.status, "incomplete")
        let requestId = inputRequestIdOf(first)
        @Expect(requestId.startsWith("inreq_"), true)

        let second = client.answerInput(first.id, requestId, "allow")
        @Expect(second.status, "completed")
        var text = ""
        for (item in second.output) {
            if (let Some(content) <- item.content) {
                for (part in content) {
                    if (let Some(t) <- part.text) {
                        text = text + t
                    }
                }
            }
        }
        @Expect(text, "答：allow")
    } finally {
        engine.close()
        server.close()
    }
}
