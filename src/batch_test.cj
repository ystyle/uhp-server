// 增量批量：高频片段要成批交付，而不是一条一调 TurnSink；但「渐进」观感必须保住。
//
// A/B 对照：同样的脚本（20 片、无延迟），开着批量 vs 关掉批量，观察 SSE 上的 delta 条数。
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

// 跑一轮，返回 (delta 条数, 文本)
func runChunked(chunks: Int64, batchMs: Int64): (Int64, String) {
    let spec = HarnessSpec()
    spec.id = "iso"
    spec.kind = "scripted"
    spec.reply = "x"
    spec.isolate = true
    spec.plugin_path = pluginBinPath()
    spec.chunks = chunks
    spec.delay_ms = 0
    let cfg = ServerConfig()
    cfg.server.event_batch_ms = batchMs
    cfg.harnesses.add(spec)
    let box = PluginBox(cfg)
    var deltas: Int64 = 0
    var text = ""
    try {
        let stream = box.client.createTaskStreamWithInput("go", harnessId: Some("iso"))
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
    } finally {
        box.close()
    }
    return (deltas, text)
}

@Test
func streaming_batches_fragments_but_keeps_progress(): Unit {
    if (!readableFile(pluginBinPath())) {
        eprintln("插件二进制缺失，先 cjpm build（或 scripts/test.sh）")
        @Expect(false, true)
        return
    }
    let chunks: Int64 = 20
    // 关掉批量：每片一个 delta
    let (offDeltas, offText) = runChunked(chunks, 0)
    @Expect(offDeltas, chunks)
    @Expect(offText.size, Int64(chunks))

    // 开着批量（25ms 窗口）：片段被聚合，delta 条数应明显少于片数，但文本必须一模一样
    let (onDeltas, onText) = runChunked(chunks, 25)
    @Expect(onText, offText)
    @Expect(onDeltas < offDeltas, true)
    @Expect(onDeltas >= 1, true)
}
