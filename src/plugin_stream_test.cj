// P1-b 的流式断言：插件进程里的多步输出，必须**逐条**作为增量到达 host 的 TurnSink，
// 而不是等回合结束一次性刷出来（后者是 P1-a 的行为）。
//
// 判据用 SSE：数 response.output_text.delta 事件的条数 > 1，并检查文本累加正确。
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

@Test
func plugin_streams_incremental_deltas(): Unit {
    let pluginBin = pluginBinPath()
    if (!readableFile(pluginBin)) {
        @Expect(true, true)
        return
    }
    let spec = HarnessSpec()
    spec.id = "iso"
    spec.kind = "scripted"
    spec.reply = "chunk "
    spec.isolate = true
    spec.plugin_path = pluginBin
    // 插件侧的 scripted backend 按 chunks 分片：4 步、每步间隔 30ms
    spec.chunks = 4
    spec.delay_ms = 30
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
        let stream = client.createTaskStreamWithInput("go", harnessId: Some("iso"))
        var deltas = 0
        var text = ""
        while (true) {
            let ev = match (stream.next()) {
                case Some(e) => e
                case None => break
            }
            match (ev) {
                case UhpEvent.OutputTextDelta(td) =>
                    deltas = deltas + 1
                    text = text + td.delta
                case _ => ()
            }
        }
        stream.close()
        // 4 步 → 至少 2 条增量事件才算「流式」；一次性回传只会有 1 条
        @Expect(deltas > 1, true)
        @Expect(text, "chunk chunk chunk chunk ")
    } finally {
        engine.close()
        server.close()
    }
}
