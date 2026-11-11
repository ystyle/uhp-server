// 探针测试：验证 cordis 的事件上行（插件 emit → 宿主 subscribeLocal）。
// P1-b 的流式增量全靠这条链路，所以先把它单独钉住，再改 run。
package uhp_server

import std.collection.{ArrayList, HashMap}
import std.sync.{AtomicBool, Mutex}
import std.unittest.*
import std.unittest.testmacro.*
import jsonvalue.*
import ystyle::cordis_core.*
import ystyle::cordis_host.*
import ystyle::jsonrpc.Result

@Test
func plugin_events_reach_host_local_subscriber(): Unit {
    let pluginBin = pluginBinPath()
    if (!readableFile(pluginBin)) {
        // 不静默跳过：插件二进制不存在时这些用例等于没跑，必须让人看见
        eprintln("插件二进制缺失，先 cjpm build（或 scripts/test.sh）")
        @Expect(false, true)
        return
    }
    let manager = PluginManager()
    let host = PluginHost(manager)
    let got = ArrayList<String>()
    let lock = Mutex()
    let _ = host.eventRegistry.subscribeLocal("harness/event", { args: Array<JsonValue> =>
        synchronized(lock) {
            got.add("n=" + args.size.toString())
        }
    })
    let args = ArrayList<String>()
    args.add("--backend")
    args.add("scripted")
    let provide = ArrayList<String>()
    provide.add("harness")
    let entry = PluginEntry("probe", pluginBin, args: args, provide: provide)
    let inst = host.launchPlugin(entry)
    match (host.awaitActive(entry.id, timeout: Duration.second * 30)) {
        case Result.Ok(_) => ()
        case Result.Err(msg) =>
            eprintln("插件未就绪：" + msg)
            @Expect(false, true)
    }
    let params = InvokeParams("harness", "ping", [JsonValue.String("probe-session")])
    let r = inst.client.call<InvokeParams, JsonValue>("invoke", params: params,
        timeout: Duration.second * 30)
    match (r) {
        case Result.Ok(_) => ()
        case Result.Err(msg) =>
            eprintln("invoke ping 失败：" + msg)
            @Expect(false, true)
    }
    // 事件是异步上行：给它一点时间
    var waited = 0
    while (waited < 3000) {
        let n = synchronized(lock) {
            got.size
        }
        if (n > 0) {
            break
        }
        sleep(Duration.millisecond * 20)
        waited = waited + 20
    }
    let received = synchronized(lock) {
        got.size
    }
    host.removePlugin(entry.id)
    @Expect(received > 0, true)
}
