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
import std.sync.{AtomicBool, AtomicInt64, Mutex}
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
    public var chunks: Int64 = 1
    public var delayMs: Int64 = 0
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
        } else if (a == "--chunks" && i + 1 < argv.size) {
            i = i + 1
            p.chunks = Int64.parse(argv[i])
        } else if (a == "--delay-ms" && i + 1 < argv.size) {
            i = i + 1
            p.delayMs = Int64.parse(argv[i])
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
            // 多步 + 步间延迟：宿主侧据此能观察到「渐进而非末尾一把刷」
            let steps = ArrayList<ScriptStep>()
            var n: Int64 = 0
            let total = if (p.chunks < 1) { 1 } else { p.chunks }
            while (n < total) {
                steps.add(ScriptStep.Text(p.reply))
                n = n + 1
            }
            return ScriptedHarness(steps.toArray(), TurnOutcome.Completed(None), delayMillis: p.delayMs)
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
    // 事件序号：宿主侧按它丢弃重复/迟到的事件
    let seq = AtomicInt64(0)

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
                case "ping" =>
                    // 探针方法：验证「插件 emit → 宿主 subscribeLocal」这条上行链路
                    ctx.emit("harness/event", [
                        JsonValue.String(jsonStr(args, 0)),
                        JsonValue.Number(1.0),
                        JsonValue.String("ping"),
                        JsonValue.String("pong")
                    ])
                    JsonValue.Boolean(true)
                case "run" =>
                    // 回合在**当前（invoke）线程**上跑，增量就地 emit 上行，返回终态。
                    // 为什么不 spawn 到别的线程：插件运行时的写通道不是线程无关的，
                    // 从任意线程 emit 会把接收/写路径搞坏（实测：首帧之后连接就断）。
                    // 于是让 invoke 持续整个回合，宿主侧另起线程等待它；cancel 由另一条 invoke 进来置标志。
                    let sessionId = jsonStr(args, 0)
                    let input = jsonStr(args, 1)
                    let slot = TurnSlot()
                    synchronized(slotsLock) {
                        slots[sessionId] = slot
                    }
                    let sink = StreamingSink(ctx, sessionId, seq)
                    let ctxArg = TurnContext(sessionId, input, "")
                    let outcome = try {
                        driver.run(ctxArg, sink, slot.cancel)
                    } catch (e: Exception) {
                        TurnOutcome.Failed("harness_error", e.message)
                    }
                    synchronized(slotsLock) {
                        slots.remove(sessionId)
                    }
                    JsonValue.String(outcomeName(outcome))
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

// P1-b 的接收端：把驱动写进 TurnSink 的语义事件逐条转成 cordis 事件上行。
//
// 参数约定（宿主侧 CordisHarnessDriver.onEvent 一一对应）：
//   [sessionId, seq, kind, text]
//   kind = text / reasoning / tool_args / tool_call / tool_result / degrade / file / outcome
// tool_call 与 tool_result 用 U+001F 分隔字段（name/args、callId/output）：
// 结构化 DTO 跨进程成本高，而字段里不会出现这个控制字符。
class StreamingSink <: TurnSink {
    private let ctx: PluginContext
    private let sessionId: String
    private let seq: AtomicInt64
    public init(ctx: PluginContext, sessionId: String, seq: AtomicInt64) {
        this.ctx = ctx
        this.sessionId = sessionId
        this.seq = seq
    }
    // 增量走 **stderr 的 JSON 行**，不走 cordis emit：
    // 实测 cordis 的 emit 在「invoke handler 线程里连续上报」时会把接收/写路径搞坏
    // （首帧之后连接就断）。stderr 由宿主 PluginManager 逐行转发，天然串行、不占协议通道，
    // 控制面（invoke）与数据面（增量）也就分开了。
    public static func emit(ctx: PluginContext, sessionId: String, seq: AtomicInt64,
                            kind: String, text: String): Unit {
        let _ = seq.fetchAdd(1)
        let m = HashMap<String, JsonValue>()
        m["ev"] = JsonValue.String("harness")
        m["sid"] = JsonValue.String(sessionId)
        m["seq"] = JsonValue.Number(Float64(seq.load()))
        m["kind"] = JsonValue.String(kind)
        m["text"] = JsonValue.String(text)
        eprintln("#UHP#" + JsonValue.Map(m).stringify())
    }
    public static func emitOutcome(ctx: PluginContext, sessionId: String, seq: AtomicInt64,
                                   status: String): Unit {
        emit(ctx, sessionId, seq, "outcome", status)
    }
    public func textDelta(delta: String): Unit {
        emit(this.ctx, this.sessionId, this.seq, "text", delta)
    }
    public func reasoningDelta(delta: String): Unit {
        emit(this.ctx, this.sessionId, this.seq, "reasoning", delta)
    }
    public func toolCallArgsDelta(delta: String): Unit {
        emit(this.ctx, this.sessionId, this.seq, "tool_args", delta)
    }
    public func toolCall(name: String, arguments: String): String {
        emit(this.ctx, this.sessionId, this.seq, "tool_call", name + "\u{1f}" + arguments)
        return name
    }
    public func toolResult(callId: String, output: String): Unit {
        emit(this.ctx, this.sessionId, this.seq, "tool_result", callId + "\u{1f}" + output)
    }
    public func degrade(reason: String): Unit {
        emit(this.ctx, this.sessionId, this.seq, "degrade", reason)
    }
    // 跨进程传字节要先编码（base64）；P1-b 只报文件名，内容留在 P1-c
    public func producedFile(filename: String, content: Array<UInt8>): Unit {
        emit(this.ctx, this.sessionId, this.seq, "file", filename)
    }
    // 问答要走完整的两轮回路（插件挂起 + 宿主转发 input_request + 下一轮答案回填），P1-c 再做
    public func ask(kind: String, prompt: String, options: Array<(String, String)>): String {
        emit(this.ctx, this.sessionId, this.seq, "ask_unsupported", prompt)
        return ""
    }
}
