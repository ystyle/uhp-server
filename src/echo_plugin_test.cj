// 文档里那套「自己写插件」的流程必须真的能跑：这里用示例插件（src/examples/echo_plugin）
// 当被测插件，验证「不改 uhp-server 一行代码、只写配置」就能把它接进来。
//
// 配置片段用的是 docs/writing-a-harness.md 里的原文，所以文档写错这里会红。
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

func echoPluginBinPath(): String {
    let direct = "target/release/bin/uhp_server.examples.echo_plugin"
    let parent = "../target/release/bin/uhp_server.examples.echo_plugin"
    if (readableFile(direct)) {
        return direct
    }
    return parent
}

@Test
func example_plugin_plugs_in_without_touching_host(): Unit {
    let bin = echoPluginBinPath()
    if (!readableFile(bin)) {
        // 不静默跳过：插件二进制不存在时这些用例等于没跑，必须让人看见
        eprintln("插件二进制缺失，先 cjpm build（或 scripts/test.sh）")
        @Expect(false, true)
        return
    }
    // 与文档一致：kind 自己起名、isolate 打开、plugin_path 指向插件、plugin_args 原样传
    let toml = """
    [server]
    port = 0

    [[tokens]]
    token = "t"
    principal = "alice"

    [[harnesses]]
    id = "mine"
    kind = "echo-plugin"
    isolate = true
    plugin_path = "$BIN$"
    plugin_args = ["--greeting", "[示例]"]
    """.replace("$BIN$", bin)
    let parsed = parseConfig(toml)
    @Expect(parsed.harnesses.size, 1)
    @Expect(parsed.harnesses[0].plugin_args.size, 2)

    let box = PluginBox(parsed)
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
        @Expect(text, "[示例]: 你好")

        // 插件产出的文件要能落到会话产物里
        let sid = match (resp.metadata) {
            case Some(m) => m.session_id ?? ""
            case None => ""
        }
        let files = box.client.sessionFiles(sid)
        @Expect(files.size, 1)
        @Expect(files[0].filename, "echo.txt")
    } finally {
        box.close()
    }
}
