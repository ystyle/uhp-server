// 大负载也要过境：产物经 stderr 的 `#UHP#` 行上报（base64），一条事件行可能有好几百 KB。
// 这条用例同时压两种传输：stdio 的逐行 framing 与 uds 的 Content-Length 帧。
package uhp_server

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import uhp.client.*
import uhp.server.*
import uhp.transport.*
import uhp.types.base.*
import uhp.types.generated.*

func bigArtifactRoundTrip(transport: String): Int64 {
    let toml = """
    [server]
    port = 0
    plugin_transport = "$T$"

    [[tokens]]
    token = "t"
    principal = "alice"

    [[harnesses]]
    id = "iso"
    kind = "scripted"
    isolate = true
    plugin_path = "$BIN$"
    file = "big.txt"
    file_size = $N$
    reply = "ok"
    """.replace("$T$", transport).replace("$BIN$", pluginBinPath()).replace("$N$", "524288")
    let box = PluginBox(parseConfig(toml))
    try {
        let resp = box.client.createTaskWithInput("go", harnessId: Some("iso"))
        @Expect(resp.status, "completed")
        let sid = match (resp.metadata) {
            case Some(m) => m.session_id ?? ""
            case None => ""
        }
        let files = box.client.sessionFiles(sid)
        @Expect(files.size, 1)
        let bytes = box.client.downloadFile(files[0].container_id ?? "", files[0].id)
        return Int64(bytes.size)
    } finally {
        box.close()
    }
}

@Test
func large_artifact_survives_both_transports(): Unit {
    if (!readableFile(pluginBinPath())) {
        eprintln("插件二进制缺失，先 cjpm build（或 scripts/test.sh）")
        @Expect(false, true)
        return
    }
    // 512 KiB：单条 base64 事件行约 700 KB，足以暴露 framing / 缓冲区问题
    @Expect(bigArtifactRoundTrip("stdio"), 524288)
    @Expect(bigArtifactRoundTrip("uds"), 524288)
}
