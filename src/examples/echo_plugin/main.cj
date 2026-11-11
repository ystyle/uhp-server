// 示例：一个最小的 harness 插件（自己写适配器照着这个改）。
//
// 它证明的是「写一个适配器插件，不需要动 uhp-server 一行代码」：
//   1. 用 cordis 的 PluginRuntime 起插件，注册 `harness` 服务的处理方法；
//   2. 回合内的增量按约定写成 stderr 的 `#UHP#{...}` JSON 行；
//   3. 把插件二进制路径 + 参数写进配置（isolate = true），就能和别的 harness 一起跑。
//
// 协议细节见 docs/writing-a-harness.md；宿主侧实现是 src/cordis_driver.cj。
package uhp_server.examples.echo_plugin

import std.collection.{ArrayList, HashMap}
import std.env.getCommandLine
import std.sync.{AtomicInt64, Mutex}
import std.time.DateTime
import stdx.encoding.base64.*
import jsonvalue.*
import ystyle::cordis_plugin.*

// ── 插件自己的参数（宿主按 plugin_args 原样传入）──
class Options {
    public var greeting: String = "echo"
}

func parseOptions(): Options {
    let o = Options()
    let argv = getCommandLine()
    var i: Int64 = 1
    while (i < argv.size) {
        if (argv[i] == "--greeting" && i + 1 < argv.size) {
            i = i + 1
            o.greeting = argv[i]
        }
        i = i + 1
    }
    return o
}

// ── 回合状态：取消标志 + 待答的提问 ──
class Turn {
    public let cancelled = AtomicBoolBox()
    private let lock = Mutex()
    private var askId: String = ""
    private var answer: Option<String> = None

    public init() {}

    public func beginAsk(id: String): Unit {
        synchronized(this.lock) {
            this.askId = id
            this.answer = None
        }
    }

    // 只接受对得上 id 的答案：迟到的旧答案不能喂给新提问
    public func offerAnswer(id: String, value: String): Bool {
        synchronized(this.lock) {
            if (id != this.askId) {
                return false
            }
            this.answer = Some(value)
            return true
        }
    }

    public func takeAnswer(): Option<String> {
        synchronized(this.lock) {
            let a = this.answer
            this.answer = None
            return a
        }
    }
}

class AtomicBoolBox {
    private let lock = Mutex()
    private var value: Bool = false
    public init() {}
    public func set(): Unit {
        synchronized(this.lock) {
            this.value = true
        }
    }
    public func get(): Bool {
        synchronized(this.lock) {
            return this.value
        }
    }
}

main(): Int64 {
    let opt = parseOptions()
    let seq = AtomicInt64(0)
    let turns = HashMap<String, Turn>()
    let turnsLock = Mutex()

    // 数据面：一条增量 = 一行 stderr。
    // 为什么走 stderr：宿主逐行转发，天然串行、不占控制面通道；JSON 便于以后加字段。
    let emit = { sessionId: String, kind: String, text: String =>
        let _ = seq.fetchAdd(1)
        let m = HashMap<String, JsonValue>()
        m["ev"] = JsonValue.String("harness")
        m["sid"] = JsonValue.String(sessionId)
        m["seq"] = JsonValue.Number(Float64(seq.load()))
        m["kind"] = JsonValue.String(kind)
        m["text"] = JsonValue.String(text)
        eprintln("#UHP#" + JsonValue.Map(m).stringify())
    }

    let handler = { ctx: PluginContext =>
        ctx.registerHandler("harness", { method: String, args: Array<JsonValue> =>
            match (method) {
                case "info" =>
                    // 宿主启动时调用一次做握手检查：能回来说明协议对上了
                    let m = HashMap<String, JsonValue>()
                    m["base"] = JsonValue.String("echo-plugin")
                    m["label"] = JsonValue.String("echo 示例插件")
                    JsonValue.Map(m)
                case "run" =>
                    let sessionId = str(args, 0)
                    let input = str(args, 1)
                    let turn = Turn()
                    synchronized(turnsLock) {
                        turns[sessionId] = turn
                    }
                    let outcome = runTurn(sessionId, input, turn, opt, emit)
                    synchronized(turnsLock) {
                        turns.remove(sessionId)
                    }
                    // 返回的是终态编码：completed / cancelled / incomplete:<reason> / failed:<code>:<msg>
                    JsonValue.String(outcome)
                case "cancel" =>
                    let sessionId = str(args, 0)
                    synchronized(turnsLock) {
                        match (turns.get(sessionId)) {
                            case Some(t) => t.cancelled.set()
                            case None => ()
                        }
                    }
                    JsonValue.Boolean(true)
                case "answer" =>
                    let sessionId = str(args, 0)
                    let requestId = str(args, 1)
                    let answer = str(args, 2)
                    let ok = synchronized(turnsLock) {
                        match (turns.get(sessionId)) {
                            case Some(t) => t.offerAnswer(requestId, answer)
                            case None => false
                        }
                    }
                    JsonValue.Boolean(ok)
                case "closeSession" => JsonValue.Boolean(true)
                case other => JsonValue.String("未知方法：" + other)
            }
        })
        ctx.log("info", "echo 插件就绪（greeting=" + opt.greeting + "）")
    }

    PluginRuntime.run("uhp-echo-example", [], ["harness"], handler)
    return 0
}

// 一轮对话：先回显（分两片，便于观察流式），输入带问号时先问一次权限，最后产出一个文本产物。
func runTurn(sessionId: String, input: String, turn: Turn, opt: Options,
             emit: (String, String, String) -> Unit): String {
    emit(sessionId, "text", opt.greeting + ": ")
    sleep(Duration.millisecond * 20)
    emit(sessionId, "text", input)
    if (turn.cancelled.get()) {
        return "cancelled"
    }
    if (input.contains("?")) {
        // 需要用户确认：上报 ask，然后挂起等宿主把答案送回来
        let payload = HashMap<String, JsonValue>()
        payload["requestId"] = JsonValue.String("echo-ask-1")
        payload["askKind"] = JsonValue.String("permission")
        payload["prompt"] = JsonValue.String("要执行这条命令吗？")
        let opts = ArrayList<JsonValue>()
        for ((id, label) in [("allow", "允许"), ("deny", "拒绝")]) {
            let o = HashMap<String, JsonValue>()
            o["id"] = JsonValue.String(id)
            o["label"] = JsonValue.String(label)
            opts.add(JsonValue.Map(o))
        }
        payload["options"] = JsonValue.Array(opts)
        turn.beginAsk("echo-ask-1")
        emit(sessionId, "ask", JsonValue.Map(payload).stringify())
        let deadline = DateTime.now().toUnixTimeStamp().toMilliseconds() + 300000
        var answer = ""
        while (DateTime.now().toUnixTimeStamp().toMilliseconds() < deadline) {
            match (turn.takeAnswer()) {
                case Some(a) =>
                    answer = a
                    break
                case None => ()
            }
            if (turn.cancelled.get()) {
                return "cancelled"
            }
            sleep(Duration.millisecond * 20)
        }
        if (answer.size == 0) {
            return "incomplete:input_required"
        }
        emit(sessionId, "text", "（确认结果：" + answer + "）")
    }
    // 产物：字节 base64 后随 file 事件上报，宿主会落到会话产物里
    let filePayload = HashMap<String, JsonValue>()
    filePayload["filename"] = JsonValue.String("echo.txt")
    filePayload["data"] = JsonValue.String(toBase64String(("echo: " + input).toArray()))
    emit(sessionId, "file", JsonValue.Map(filePayload).stringify())
    return "completed"
}

func str(args: Array<JsonValue>, i: Int64): String {
    if (i >= args.size) {
        return ""
    }
    return match (args[i]) {
        case JsonValue.String(s) => s
        case _ => ""
    }
}
