// CordisHarnessDriver：把「一个 harness 适配器」放进独立进程，host 侧只做代理。
//
// 为什么（P1）：适配器有状态（拉 agent 子进程、持长连接、攒会话作用域）。放进独立进程后，
// 一个适配器崩了/卡住只丢一路 harness，host 与其它 harness 不受影响；卸载=杀进程，资源由 OS 回收。
//
// 进程由 cordis-cj 托管（PluginHost + PluginManager）：拉起、握手、stderr 转发、终止回收都是它的活。
// 本类只做三件事：把 HarnessDriver 的调用翻译成 invoke、把插件事件翻译成 TurnSink、把生命周期接上。
package uhp_server

import std.collection.{ArrayList, HashMap}
import std.sync.{AtomicBool, Mutex}
import std.io.ByteBuffer
import stdx.encoding.json.stream.JsonReader
import jsonvalue.*
import ystyle::cordis_core.*
import ystyle::cordis_host.*
import ystyle::jsonrpc.Result
import uhp.server.*
import uhp.types.generated.*
import uhp_acp.nowMillis

const HARNESS_EVENT = "harness/event"

// 一路回合的接收端：插件会把增量事件按 sessionId 回传，host 按会话找到它。
class TurnSinkSlot {
    public var sink: Option<TurnSink> = None
    public var outcome: Option<String> = None
    public let cancel = CancelToken()
    public var lastSeq: Int64 = 0
}

public class CordisHarnessDriver <: HarnessDriver & HarnessLifecycle {
    private let pluginSource: String
    private let pluginArgs: Array<String>
    private let label: String
    private let baseName: String
    private let lock = Mutex()
    private var host: Option<PluginHost> = None
    private var instance: Option<PluginInstance> = None
    private let slots: HashMap<String, TurnSinkSlot> = HashMap<String, TurnSinkSlot>()
    private let timeoutSeconds: Int64

    public init(pluginSource: String, pluginArgs: Array<String>, base: String, label: String,
                timeoutSeconds!: Int64 = 600) {
        this.pluginSource = pluginSource
        this.pluginArgs = pluginArgs
        this.baseName = base
        this.label = label
        this.timeoutSeconds = timeoutSeconds
    }

    public func base(): String {
        return this.baseName
    }

    public func baseLabel(): String {
        return this.label
    }

    public func models(): Array<Model> {
        let m = Model()
        m.id = this.baseName + "-plugin"
        m.label = this.label
        m.available = true
        m.default = Some(true)
        return [m]
    }

    public func capabilities(): HarnessCapabilities {
        // 跨进程的问答（permission/elicitation 两轮回路）还没接，先如实报不支持
        return HarnessCapabilities(false, true)
    }

    public func run(ctx: TurnContext, sink: TurnSink, cancel: CancelToken): TurnOutcome {
        let inst = match (this.ensurePlugin()) {
            case Some(i) => i
            case None => return TurnOutcome.Failed("harness_error", "harness 插件不可用")
        }
        let slot = TurnSinkSlot()
        slot.sink = Some(sink)
        synchronized(this.lock) {
            this.slots[ctx.sessionId] = slot
        }
        // P1-b：回合的 invoke 会一直挂到回合结束（插件在自己的处理线程上跑回合 + 逐条 emit），
        // 所以这里另起一条线程等结果，主线程负责把取消转发出去、并在超时后收口。
        // 增量由事件订阅（onEvent）直接写进 sink，不必等 invoke 返回。
        let outcomeBox = OutcomeBox()
        let self = this
        let sessionId = ctx.sessionId
        let input = ctx.input
        spawn {
            let r = self.invoke(inst, "run", [JsonValue.String(sessionId), JsonValue.String(input)])
            let status = match (r) {
                case Some(v) => asString(v)
                case None => "failed:harness_error:插件调用失败"
            }
            outcomeBox.set(status)
            synchronized(self.lock) {
                self.slots.remove(sessionId)
            }
        }
        let deadline = nowMillis() + this.timeoutSeconds * 1000
        while (nowMillis() < deadline) {
            match (outcomeBox.get()) {
                case Some(status) => return decodeOutcome(status)
                case None => ()
            }
            if (cancel.isCancelled()) {
                // 取消是另一条 invoke：插件在自己的线程池里处理，不受正在跑的回合阻塞
                let _ = this.invoke(inst, "cancel", [JsonValue.String(ctx.sessionId)])
            }
            sleep(Duration.millisecond * 10)
        }
        synchronized(this.lock) {
            this.slots.remove(ctx.sessionId)
        }
        let _ = this.invoke(inst, "cancel", [JsonValue.String(ctx.sessionId)])
        return TurnOutcome.Failed("harness_error", "harness 插件回合超时")
    }

    // 会话级回收：让插件里的适配器把 agent 侧作用域还回去
    public func closeSession(sessionId: String): Unit {
        match (this.instance) {
            case Some(inst) =>
                let _ = this.invoke(inst, "closeSession", [JsonValue.String(sessionId)])
            case None => ()
        }
    }

    // 进程级回收：终止插件进程（cordis 负责 kill + wait 回收，不留僵尸）
    public func close(): Unit {
        let (h, i): (Option<PluginHost>, Option<PluginInstance>) = synchronized(this.lock) {
            let host = this.host
            let inst = this.instance
            this.host = None
            this.instance = None
            (host, inst)
        }
        match (i) {
            case Some(inst) => match (h) {
                case Some(host) => host.removePlugin(inst.entry.id)
                case None => ()
            }
            case None => ()
        }
    }

    // ---------- 内部 ----------

    private func ensurePlugin(): Option<PluginInstance> {
        synchronized(this.lock) {
            match (this.instance) {
                case Some(i) => return Some(i)
                case None => ()
            }
        }
        // 启动在锁外做：拉起进程要等握手，抱着锁会把其它会话挡住
        let manager = PluginManager({ id: String, line: String =>
            // 数据面：插件把增量写成 #UHP# 开头的 JSON 行，从 stderr 转发上来
            if (line.startsWith("#UHP#")) {
                this.onEventLine(line)
            } else {
                eprintln("[plugin:" + id + "] " + line)
            }
        })
        let host = PluginHost(manager)
        let args = ArrayList<String>()
        for (a in this.pluginArgs) {
            args.add(a)
        }
        let provide = ArrayList<String>()
        provide.add("harness")
        let entry = PluginEntry("harness-" + this.baseName, this.pluginSource, args: args, provide: provide)
        let inst = try {
            host.launchPlugin(entry)
        } catch (e: Exception) {
            eprintln("[harness-plugin] 拉起失败：" + e.message)
            return None
        }
        // 必须等握手完成再 invoke：launchPlugin 返回时插件可能还在 initialize，
        // 此时它的服务表是空的，invoke 会被回成 INVOKE-ERROR。
        let active = match (host.awaitActive(entry.id, timeout: Duration.second * 30)) {
            case Result.Ok(a) => a
            case Result.Err(msg) =>
                eprintln("[harness-plugin] 插件未就绪：" + msg)
                return None
        }
        // 事件订阅：插件的增量上报按 sessionId 分派给对应回合的 sink
        synchronized(this.lock) {
            // 并发首次调用时可能已经有人装好了：装好的那份为准，本次拉起的实例关掉
            match (this.instance) {
                case Some(existing) =>
                    try {
                        host.removePlugin(entry.id)
                    } catch (e: Exception) {
                        ()
                    }
                    return Some(existing)
                case None =>
                    this.host = Some(host)
                    this.instance = Some(active)
            }
        }
        return Some(active)
    }

    // 解析一行上报：{"ev":"harness","sid":...,"seq":...,"kind":...,"text":...}
    // 任何解析失败都只记日志、不抛出——插件的一条坏行不该影响宿主。
    private func onEventLine(line: String): Unit {
        let v = try {
            JsonValue.fromJson(JsonReader(ByteBuffer(line[5..line.size].toArray())))
        } catch (e: Exception) {
            eprintln("[harness-plugin] 坏事件行：" + line)
            return
        }
        let fields = match (v) {
            case JsonValue.Map(m) => m
            case _ => return
        }
        let sessionId = asString(fields.get("sid") ?? JsonValue.Null)
        let seqN = asInt(fields.get("seq") ?? JsonValue.Null)
        let kind = asString(fields.get("kind") ?? JsonValue.Null)
        let text = asString(fields.get("text") ?? JsonValue.Null)
        let (sinkOpt, stale): (Option<TurnSink>, Bool) = synchronized(this.lock) {
            match (this.slots.get(sessionId)) {
                case Some(slot) =>
                    // 迟到/重复的事件（seq 不大于已见）直接丢弃：跨进程传输不保证顺序
                    let dup = seqN <= slot.lastSeq
                    if (!dup) {
                        slot.lastSeq = seqN
                    }
                    (slot.sink, dup)
                case None => (None, true)
            }
        }
        if (stale) {
            return
        }
        match (sinkOpt) {
            case Some(sink) => this.dispatch(sink, sessionId, kind, text)
            case None => ()
        }
    }

    private func dispatch(sink: TurnSink, sessionId: String, kind: String, text: String): Unit {
        match (kind) {
            case "text" => sink.textDelta(text)
            case "reasoning" => sink.reasoningDelta(text)
            case "tool_args" => sink.toolCallArgsDelta(text)
            case "tool_call" =>
                let parts = text.split("\u{1f}")
                let name = if (parts.size > 0) { parts[0] } else { text }
                let args = if (parts.size > 1) { parts[1] } else { "{}" }
                let _ = sink.toolCall(name, args)
            case "tool_result" =>
                let parts = text.split("\u{1f}")
                let callId = if (parts.size > 0) { parts[0] } else { "" }
                let out = if (parts.size > 1) { parts[1] } else { "" }
                sink.toolResult(callId, out)
            case "degrade" => sink.degrade(text)
            case "file" =>
                // 跨进程只带文件名：字节内容要先编码，留到 P1-c
                sink.producedFile(text, [])
            case "ask_unsupported" =>
                eprintln("[harness-plugin] 插件侧发起提问但跨进程问答未实现：" + text)
            case "outcome" =>
                synchronized(this.lock) {
                    match (this.slots.get(sessionId)) {
                        case Some(slot) =>
                            slot.outcome = Some(text)
                            slot.sink = None
                        case None => ()
                    }
                }
            case _ => ()
        }
    }

    private func invoke(inst: PluginInstance, method: String, args: Array<JsonValue>): Option<JsonValue> {
        let params = InvokeParams("harness", method, args)
        return match (inst.client.call<InvokeParams, JsonValue>("invoke", params: params,
            timeout: Duration.second * 60)) {
            case Result.Ok(v) => Some(v)
            case Result.Err(msg) =>
                eprintln("[harness-plugin] invoke " + method + " 失败：" + msg)
                None
        }
    }
}

func asString(v: JsonValue): String {
    return match (v) {
        case JsonValue.String(s) => s
        case _ => ""
    }
}

func asInt(v: JsonValue): Int64 {
    return match (v) {
        case JsonValue.Number(n) => Int64(n)
        case _ => 0
    }
}

// 插件回传的终态编码（src/plugin/main.cj 的 outcomeName）：
//   completed / cancelled / incomplete:<reason> / failed:<code>:<message>
func decodeOutcome(s: String): TurnOutcome {
    if (s == "completed") {
        return TurnOutcome.Completed(None)
    }
    if (s == "cancelled") {
        return TurnOutcome.Cancelled(None)
    }
    if (s.startsWith("incomplete:")) {
        let reason = s["incomplete:".size..s.size]
        if (reason == "input_required") {
            return TurnOutcome.Incomplete(IncompleteReason.InputRequired, None)
        }
        if (reason == "max_steps") {
            return TurnOutcome.Incomplete(IncompleteReason.MaxSteps, None)
        }
        if (reason == "timeout") {
            return TurnOutcome.Incomplete(IncompleteReason.Timeout, None)
        }
        return TurnOutcome.Incomplete(IncompleteReason.Other(reason), None)
    }
    if (s.startsWith("failed:")) {
        let rest = s["failed:".size..s.size]
        let parts = rest.split(":")
        let code = if (parts.size > 0) { parts[0] } else { "harness_error" }
        let msg = if (parts.size > 1) { rest[code.size + 1..rest.size] } else { "harness failed" }
        return TurnOutcome.Failed(code, msg)
    }
    return TurnOutcome.Failed("harness_error", "未知终态：" + s)
}

// 回合结果的交接槽：invoke 线程写，主线程读
class OutcomeBox {
    private let lock = Mutex()
    private var value: Option<String> = None
    public init() {}
    public func set(v: String): Unit {
        synchronized(this.lock) {
            this.value = Some(v)
        }
    }
    public func get(): Option<String> {
        synchronized(this.lock) {
            return this.value
        }
    }
}
