// harness 插件进程：把「一个 harness 适配器」放到独立进程里跑。
//
// 为什么要有它（P1）：适配器是有状态的（拉起 agent 子进程、持长连接、攒会话作用域）。
// 放在 host 进程里，一个适配器崩了/卡了会把整个服务带走；放独立进程里，host 只丢一路 harness。
//
// 协议（宿主侧见 CordisHarnessDriver）：cordis 的 `harness` 服务，四个方法 + 一条事件流：
//   info()                       -> {base,label}
//   run(sessionId, input)        -> 受理即返回；回合结果通过事件回传
//   cancel(sessionId)            -> 协作式取消
//   closeSession(sessionId)      -> 会话级回收（驱动实现了 HarnessLifecycle 才有动作）
// 事件 `harness/event`：args = [sessionId, seq, kind, text]
//   kind = text / reasoning / outcome
// 为什么「run 立即返回 + 事件回传」而不是让 run 等回合结束：
//   宿主需要在回合进行中持续收增量；cordis 的 invoke 是一问一答，长阻塞会占住转发路径。
package uhp_server.plugin

import std.collection.{ArrayList, HashMap}
import std.convert.*
import std.env.getCommandLine
import std.sync.{AtomicBool, Mutex}
import jsonvalue.*
import ystyle::cordis_plugin.*
import uhp.server.*
import uhp_acp.*
import uhp_opencode.*

const EVENT_NAME = "harness/event"

// 插件私有配置：从命令行参数来（宿主拉起时决定），不做热更新——换配置就换进程。
class PluginArgs {
    public var backend: String = "scripted"
    public var reply: String = "plugin reply"
    public var command: String = ""
    public var agentArgs: Array<String> = []
    public var cwd: String = "/tmp"
    public var sessionMode: String = "serial"
    public var timeoutSeconds: Int64 = 600
}

func parseArgs(): PluginArgs {
    let p = PluginArgs()
    let argv = getCommandLine()
    var extra = ArrayList<String>()
    var i: Int64 = 1
    while (i < argv.size) {
        let a = argv[i]
        if (a == "--backend" && i + 1 < argv.size) {
            i = i + 1
            p.backend = argv[i]
        } else if (a == "--reply" && i + 1 < argv.size) {
            i = i + 1
            p.reply = argv[i]
        } else if (a == "--command" && i + 1 < argv.size) {
            i = i + 1
            p.command = argv[i]
        } else if (a == "--cwd" && i + 1 < argv.size) {
            i = i + 1
            p.cwd = argv[i]
        } else if (a == "--session-mode" && i + 1 < argv.size) {
            i = i + 1
            p.sessionMode = argv[i]
        } else if (a == "--timeout" && i + 1 < argv.size) {
            i = i + 1
            p.timeoutSeconds = Int64.parse(argv[i])
        } else if (a == "--arg" && i + 1 < argv.size) {
            i = i + 1
            extra.add(argv[i])
        }
        i = i + 1
    }
    p.agentArgs = extra.toArray()
    return p
}

func buildDriver(p: PluginArgs, label: String): HarnessDriver {
    match (p.backend) {
        case "scripted" =>
            return ScriptedHarness([ScriptStep.Text(p.reply)], TurnOutcome.Completed(None))
        case "acp" =>
            if (p.command.size == 0) {
                throw Exception("backend=acp 需要 --command")
            }
            let mode = if (p.sessionMode == "parallel") { AcpSessionMode.Parallel } else { AcpSessionMode.Serial }
            return AcpDriver(AcpOptions(p.command, args: p.agentArgs, cwd: p.cwd, label: label,
                timeoutSeconds: p.timeoutSeconds, sessionMode: mode))
        case "opencode" =>
            return OpencodeDriver(OpencodeOptions(p.command, p.cwd, label: label,
                timeoutSeconds: p.timeoutSeconds))
        case other =>
            throw Exception("未知 backend：" + other)
    }
}

// 回合状态：一个会话一个（同一会话的回合由宿主保证串行）
class TurnSlot {
    public let cancel = CancelToken()
}

main(): Int64 {
    let p = parseArgs()
    let slots = HashMap<String, TurnSlot>()
    let slotsLock = Mutex()

    let handler = { ctx: PluginContext =>
        let driver = try {
            buildDriver(p, "plugin:" + p.backend)
        } catch (e: Exception) {
            ctx.log("error", "构建驱动失败：" + e.message)
            throw e
        }

        ctx.registerHandler("harness", { method: String, args: Array<JsonValue> =>
            match (method) {
                case "info" =>
                    let obj = HashMap<String, JsonValue>()
                    obj["base"] = JsonValue.String(driver.base())
                    obj["label"] = JsonValue.String(driver.baseLabel())
                    JsonValue.Map(obj)
                case "run" =>
                    let sessionId = jsonStr(args, 0)
                    let input = jsonStr(args, 1)
                    let slot = TurnSlot()
                    synchronized(slotsLock) {
                        slots[sessionId] = slot
                    }
                    let sink = BufferedSink()
                    // P1-a：整轮同步执行，增量在插件里缓冲后一次性回传。
                    // 为什么先这样：跨进程逐条推增量要走事件上行 + 订阅，链路上还有坑；
                    // 先把「进程边界 + 生命周期 + 终态映射」跑通，流式留到 P1-b。
                    let ctxArg = TurnContext(sessionId, input, "")
                    let outcome = driver.run(ctxArg, sink, slot.cancel)
                    synchronized(slotsLock) {
                        slots.remove(sessionId)
                    }
                    let result = HashMap<String, JsonValue>()
                    result["status"] = JsonValue.String(outcomeName(outcome))
                    result["text"] = JsonValue.String(sink.text)
                    result["reasoning"] = JsonValue.String(sink.reasoning)
                    JsonValue.Map(result)
                case "cancel" =>
                    let sessionId = jsonStr(args, 0)
                    synchronized(slotsLock) {
                        match (slots.get(sessionId)) {
                            case Some(s) => s.cancel.cancel()
                            case None => ()
                        }
                    }
                    JsonValue.Boolean(true)
                case "closeSession" =>
                    let sessionId = jsonStr(args, 0)
                    match (driver) {
                        case lc: HarnessLifecycle => lc.closeSession(sessionId)
                        case _ => ()
                    }
                    JsonValue.Boolean(true)
                case _ => JsonValue.String("未知方法：" + method)
            }
        })
        ctx.log("info", "harness 插件就绪（backend=" + p.backend + "）")
    }

    PluginRuntime.run("uhp-harness-plugin", [], ["harness"], handler)
    return 0
}

func jsonStr(args: Array<JsonValue>, i: Int64): String {
    if (i >= args.size) {
        return ""
    }
    return match (args[i]) {
        case JsonValue.String(s) => s
        case _ => ""
    }
}

// 回合终态编码成一行文本，宿主侧解回来。输入/输出都用最小的字符串约定，
// 避免在跨进程边界上再定义一套 DTO。
func outcomeName(o: TurnOutcome): String {
    return match (o) {
        case TurnOutcome.Completed(_) => "completed"
        case TurnOutcome.Incomplete(reason, _) => "incomplete:" + incompleteReasonName(reason)
        case TurnOutcome.Failed(code, msg) => "failed:" + code + ":" + msg
        case TurnOutcome.Cancelled(_) => "cancelled"
    }
}

// P1-a 的接收端：把增量就地缓冲。跨进程逐条推流要事件上行，留到 P1-b。
class BufferedSink <: TurnSink {
    public var text: String = ""
    public var reasoning: String = ""
    public init() {}
    public func textDelta(delta: String): Unit { this.text = this.text + delta }
    public func reasoningDelta(delta: String): Unit { this.reasoning = this.reasoning + delta }
    public func toolCallArgsDelta(delta: String): Unit { () }
    public func toolCall(name: String, arguments: String): String { name }
    public func toolResult(callId: String, output: String): Unit { () }
    public func degrade(reason: String): Unit { () }
    public func ask(kind: String, prompt: String, options: Array<(String, String)>): String { "" }
    public func producedFile(filename: String, content: Array<UInt8>): Unit { () }
}
