// 端到端：真起一个 UHP server（scripted harness，不接模型），用 SDK 的 client 走 HTTP。
// 这条用例覆盖：discovery / harness 列表 / 任务创建 / 文本输出 / 未知 harness 的 404 映射。
package uhp_server

import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*
import stdx.net.http.*
import uhp.client.*
import uhp.server.*
import uhp.transport.*
import uhp.types.base.*
import uhp.types.generated.*

class TestServer {
    public let port: UInt16
    public let client: UhpClient
    private let server: Server

    public init(reply: String) {
        let driver = ScriptedHarness([ScriptStep.Text(reply)], TurnOutcome.Completed(None))
        let engine = Engine([ConfiguredHarness("echo", "echo", "scripted", "auto", driver)],
            cls: ConformanceClass.Full)
        let tokens = HashMap<String, String>()
        tokens["test-token"] = "alice"
        let uhp = UhpHttpServer(engine, Authenticator(tokens))
        this.server = ServerBuilder().addr("127.0.0.1").port(0).distributor(uhp.distributor()).build()
        let s = this.server
        spawn {
            s.serve()
        }
        // port(0) 由 serve() 绑定后才可读：先等端口出现，再谈就绪
        var bound: UInt16 = 0
        for (_ in 0..500) {
            bound = this.server.port
            if (bound != 0) {
                break
            }
            sleep(Duration.millisecond * 10)
        }
        this.port = bound
        let url = "http://127.0.0.1:" + this.port.toString()
        this.client = UhpClient(url, "test-token", StdHttpTransport(url))
        // 等监听就绪：discover 成功即视为就绪（失败重试）
        var ready = false
        for (_ in 0..200) {
            try {
                let _ = this.client.discover()
                ready = true
                break
            } catch (e: Exception) {
                sleep(Duration.millisecond * 20)
            }
        }
        if (!ready) {
            throw Exception("测试 server 未就绪")
        }
    }

    public func close(): Unit {
        this.server.close()
    }
}

@Test
func e2e_discovery_and_harness_list(): Unit {
    let ts = TestServer("hello from scripted")
    try {
        let d = ts.client.discover()
        @Expect(d.protocol, "uhp")
        @Expect(d.versions.size > 0, true)
        let hs = ts.client.harnesses()
        @Expect(hs.size, 1)
        @Expect(hs[0].id, "echo")
    } finally {
        ts.close()
    }
}

@Test
func e2e_task_returns_scripted_text(): Unit {
    let ts = TestServer("hello from scripted")
    try {
        let resp = ts.client.createTaskWithInput("ping", harnessId: Some("echo"))
        @Expect(resp.status, "completed")
        @Expect(resp.id.startsWith("resp_"), true)
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
        @Expect(text, "hello from scripted")
    } finally {
        ts.close()
    }
}

@Test
func e2e_unknown_harness_is_404(): Unit {
    let ts = TestServer("x")
    try {
        var code = ""
        try {
            let _ = ts.client.createTaskWithInput("ping", harnessId: Some("nope"))
        } catch (e: UhpError) {
            code = e.code()
        }
        @Expect(code, "harness_not_found")
    } finally {
        ts.close()
    }
}
