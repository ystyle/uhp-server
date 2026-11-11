// 插件的两种通信方式都要能跑：stdio（逐行 JSON，默认）与 uds（unix socket + Content-Length 帧）。
//
// 为什么值得单独钉住：传输层是 cordis 的 PluginManager 里二选一，切错了表现是「拉起后握手超时」
// 或「事件收不到」，不容易一眼看出是配置问题。
package uhp_server

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import uhp.client.*
import uhp.server.*
import uhp.transport.*
import uhp.types.base.*
import uhp.types.generated.*

// 用示例插件跑一轮，返回文本；transport 决定宿主与插件怎么通信
func runWithTransport(transport: String): String {
    let toml = """
    [server]
    port = 0
    plugin_transport = "$T$"
    event_batch_ms = 0

    [[tokens]]
    token = "t"
    principal = "alice"

    [[harnesses]]
    id = "mine"
    kind = "echo-plugin"
    isolate = true
    plugin_path = "$BIN$"
    plugin_args = ["--greeting", "[示例]"]
    """.replace("$T$", transport).replace("$BIN$", echoPluginBinPath())
    let box = PluginBox(parseConfig(toml))
    try {
        let resp = box.client.createTaskWithInput("你好", harnessId: Some("mine"))
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
        return text
    } finally {
        box.close()
    }
}

@Test
func plugin_works_over_stdio_and_uds(): Unit {
    if (!readableFile(echoPluginBinPath())) {
        eprintln("插件二进制缺失，先 cjpm build（或 scripts/test.sh）")
        @Expect(false, true)
        return
    }
    @Expect(runWithTransport("stdio"), "[示例]: 你好")
    @Expect(runWithTransport("uds"), "[示例]: 你好")
}
