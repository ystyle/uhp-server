// CordisHarnessDriver：把「一个 harness 适配器」放进独立进程，host 侧只做代理。
//
// 为什么（P1）：适配器有状态（拉 agent 子进程、持长连接、攒会话作用域）。放进独立进程后，
// 一个适配器崩了/卡住只丢一路 harness，host 与其它 harness 不受影响；卸载=杀进程，资源由 OS 回收。
//
// 进程由 cordis-cj 托管（PluginHost + PluginManager）：拉起、握手、stderr 转发、终止回收都是它的活。
// 本类只做三件事：把 HarnessDriver 的调用翻译成 invoke、把插件事件翻译成 TurnSink、把生命周期接上。
package uhp_server

import std.collection.{ArrayList, HashMap}
import std.fs.{Path, removeIfExists}
import std.sync.{AtomicBool, Mutex}
import std.io.ByteBuffer
import stdx.encoding.base64.*
import stdx.encoding.json.stream.JsonReader
import jsonvalue.*
import ystyle::cordis_core.*
import ystyle::cordis_host.*
import ystyle::jsonrpc.Result
import uhp.server.*
import uhp.types.generated.*
import uhp_acp.nowMillis

const HARNESS_EVENT = "harness/event"

// 增量批量窗口的字节上限：攒到这么多就不等窗口，立刻冲一次
const FLUSH_BYTES: Int64 = 4096

// 参与批量的片段类型：高频、纯增量、彼此同类。
// tool_call / tool_result / file / outcome 不参与——它们有顺序与即时性要求，不能攒。
func isBufferedKind(kind: String): Bool {
    return kind == "text" || kind == "reasoning" || kind == "tool_args"
}

// 一次待交付的批次（在锁外交付，避免持锁调用 TurnSink）
class PendingBatch {
    public let sink: Option<TurnSink>
    public let items: Array<(String, String)>
    public init(sink: Option<TurnSink>, items: Array<(String, String)>) {
        this.sink = sink
        this.items = items
    }
}

// 一路回合的接收端：插件会把增量事件按 sessionId 回传，host 按会话找到它。
class TurnSinkSlot {
    public var sink: Option<TurnSink> = None
    public var outcome: Option<String> = None
    public let cancel = CancelToken()
    public var lastSeq: Int64 = 0
    // 插件要提问时先落在这里：TurnSink.ask 必须由回合线程调用（它要发 input_request），
    // 而事件是在 stderr 转发线程上收到的，所以分两步：线程登记 → 回合线程取走并上报。
    public var askEvent: Option<AskEvent> = None
    // 批量窗口：待交付的片段（kind, text）与首片时间
    public let pending: ArrayList<(String, String)> = ArrayList<(String, String)>()
    public var pendingBytes: Int64 = 0
    public var lastFlushMs: Int64 = 0
}

// 插件侧的一次提问（对应 UHP 的一个 input_request）
class AskEvent {
    public let requestId: String
    public let kind: String
    public let prompt: String
    public let options: Array<(String, String)>
    public init(requestId: String, kind: String, prompt: String, options: Array<(String, String)>) {
        this.requestId = requestId
        this.kind = kind
        this.prompt = prompt
        this.options = options
    }
}

public class CordisHarnessDriver <: HarnessDriver & HarnessLifecycle {
    private let pluginSource: String
    private let pluginArgs: Array<String>
    private let label: String
    private let baseName: String
    private let lock = Mutex()
    private var host: Option<PluginHost> = None
    private var manager: Option<PluginManager> = None
    private var instance: Option<PluginInstance> = None
    private let slots: HashMap<String, TurnSinkSlot> = HashMap<String, TurnSinkSlot>()
    // 已经上报给客户端、等下一轮答案的请求：sessionId -> 插件的 requestId
    private let pendingAsks: HashMap<String, String> = HashMap<String, String>()
    // 回合结果槽：插件那条 invoke 可能跨两轮（提问中断 + 答案续跑），所以槽要在驱动里存着
    private let outcomes: HashMap<String, OutcomeBox> = HashMap<String, OutcomeBox>()
    private let timeoutSeconds: Int64
    // 批量窗口（毫秒）：<= 0 表示关闭，每条都立即转发
    private let batchMs: Int64
    private var flusherOn: Bool = false
    // 插件通信方式：stdio（默认）| uds
    private let transport: String
    private var udsSocket: String = ""

    public init(pluginSource: String, pluginArgs: Array<String>, base: String, label: String,
                timeoutSeconds!: Int64 = 600, batchMs!: Int64 = 25, transport!: String = "stdio") {
        this.pluginSource = pluginSource
        this.pluginArgs = pluginArgs
        this.baseName = base
        this.label = label
        this.timeoutSeconds = timeoutSeconds
        this.batchMs = batchMs
        this.transport = transport
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
        let outcomeBox = synchronized(this.lock) {
            match (this.outcomes.get(ctx.sessionId)) {
                case Some(b) => b
                case None =>
                    let b = OutcomeBox()
                    this.outcomes[ctx.sessionId] = b
                    b
            }
        }

        // 这一段是「回答问题」的续跑：插件那条 run invoke 还没返回（驱动挂在 ask 上），
        // 所以不能重新发起回合，只把答案送回去，然后接着等同一个结果槽。
        var resumed = false
        if (ctx.answers.size > 0) {
            let pending = synchronized(this.lock) {
                this.pendingAsks.remove(ctx.sessionId)
            }
            match (pending) {
                case Some(reqId) =>
                    resumed = true
                    let _ = this.invoke(inst, "answer", [JsonValue.String(ctx.sessionId),
                        JsonValue.String(reqId), JsonValue.String(ctx.answers[0])])
                case None => ()
            }
        }
        if (!resumed) {
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
            }
        }

        let deadline = nowMillis() + this.timeoutSeconds * 1000
        while (nowMillis() < deadline) {
            // 1) 回合结束
            match (outcomeBox.get()) {
                case Some(status) =>
                    // 终态是通过 invoke 返回拿到的（不一定有 outcome 事件），必须在这里冲刷
                    this.flushSession(ctx.sessionId)
                    synchronized(this.lock) {
                        this.slots.remove(ctx.sessionId)
                        this.outcomes.remove(ctx.sessionId)
                        this.pendingAsks.remove(ctx.sessionId)
                    }
                    return decodeOutcome(status)
                case None => ()
            }
            // 2) 插件提问：上报成 input_request，本轮以 incomplete 收口（下一轮带答案回来）
            // 闭包内不做类型推断兜底：显式标注局部量
            let ask: Option<AskEvent> = synchronized(this.lock) {
                match (this.slots.get(ctx.sessionId)) {
                    case Some(s) =>
                        let a = s.askEvent
                        s.askEvent = None
                        a
                    case None => None
                }
            }
            match (ask) {
                case Some(a) =>
                    // TurnSink.ask 会生成 UHP 的 input_request 并返回它的 id
                    let requestId = sink.ask(a.kind, a.prompt, a.options)
                    synchronized(this.lock) {
                        this.pendingAsks[ctx.sessionId] = a.requestId
                    }
                    this.flushSession(ctx.sessionId)
                    eprintln("[harness-plugin] 提问已上报 request=" + requestId + " plugin=" + a.requestId)
                    return TurnOutcome.Incomplete(IncompleteReason.InputRequired, None)
                case None => ()
            }
            // 3) 插件进程没了：在跑的回合立刻失败，不要干等超时
            if (this.pluginExited(inst)) {
                synchronized(this.lock) {
                    this.slots.remove(ctx.sessionId)
                    this.outcomes.remove(ctx.sessionId)
                    this.instance = None
                    this.host = None
                    this.manager = None
                }
                return TurnOutcome.Failed("harness_error", "harness 插件进程已退出")
            }
            if (cancel.isCancelled()) {
                // 取消是另一条 invoke：插件在自己的线程池里处理，不受正在跑的回合阻塞
                let _ = this.invoke(inst, "cancel", [JsonValue.String(ctx.sessionId)])
            }
            sleep(Duration.millisecond * 10)
        }
        synchronized(this.lock) {
            this.slots.remove(ctx.sessionId)
            this.outcomes.remove(ctx.sessionId)
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

    // 插件进程是否已退出。退出之后 instance 里的连接都不可用了，
    // 所以下一次 run 会重新拉起（ensurePlugin 里 instance 为 None 就再拉一个）。
    private func pluginExited(inst: PluginInstance): Bool {
        return match (this.manager) {
            case Some(m) => m.isExited(inst)
            case None => false
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
        // UDS 的 socket 文件由宿主创建，进程退出前删掉（bind 前 cordis 也会清残留）
        if (this.udsSocket.size > 0) {
            try {
                removeIfExists(Path(this.udsSocket))
            } catch (e: Exception) {
                ()
            }
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
        let logger: (String, String) -> Unit = { id: String, line: String =>
            // 数据面：插件把增量写成 #UHP# 开头的 JSON 行，从 stderr 转发上来
            if (line.startsWith("#UHP#")) {
                this.onEventLine(line)
            } else {
                eprintln("[plugin:" + id + "] " + line)
            }
        }
        // stdio：逐行 JSON 走管道；uds：宿主 listen 一个 unix socket，插件以客户端身份连。
        // UDS 路径有长度上限（~108 字节），所以用短前缀 + 时间戳，别拼长 harness 名。
        let manager = if (this.transport == "uds") {
            let sock = "/tmp/uhp-h-" + nowMillis().toString() + ".sock"
            this.udsSocket = sock
            PluginManager(sock, logger)
        } else {
            PluginManager(logger)
        }
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
        // 等插件真正可用：awaitReady = Active（握手 + provide 齐）**且**收到 ready（实现已注册）。
        //
        // 只用 awaitActive 不够：cordis 的插件顺序是「先 provide 再跑 handler」，
        // 拿到 provide 时 ctx.registerHandler 可能还没执行，此刻 invoke 会被回成
        // "INVOKE-ERROR: service 'harness' not provided by this plugin"（实测偶发）。
        let active = match (host.awaitReady(entry.id, timeout: Duration.second * 30)) {
            case Result.Ok(a) => a
            case Result.Err(msg) =>
                eprintln("[harness-plugin] 插件未就绪：" + msg)
                return None
        }
        // 再补一道结构校验：info 必须返回带 base 的对象。
        // 「有回包」不等于「服务可用」——cordis 会把插件侧异常包成字符串回包。
        if (!this.waitPluginReady(active)) {
            eprintln("[harness-plugin] 插件未应答有效的 info：可能不是 harness 插件（" + this.pluginSource + "）")
            return None
        }
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
                    this.manager = Some(manager)
                    this.instance = Some(active)
            }
        }
        this.ensureFlusher()
        return Some(active)
    }

    // 等插件真正可用：轮询 info 直到返回带 base 的对象（最多 10s）
    private func waitPluginReady(inst: PluginInstance): Bool {
        let deadline = nowMillis() + 10000
        while (nowMillis() < deadline) {
            match (this.invoke(inst, "info", [])) {
                case Some(v) =>
                    if (this.isInfoShaped(v)) {
                        return true
                    }
                case None => ()
            }
            sleep(Duration.millisecond * 20)
        }
        return false
    }

    // info 的约定返回：{base: "…", label: "…"}。
    // 注意 cordis 会把插件侧异常包成字符串回包（"INVOKE-ERROR: …"），
    // 所以「有回包」不等于「服务已注册」，必须校验结构。
    private func isInfoShaped(v: JsonValue): Bool {
        let fields = match (v) {
            case JsonValue.Map(m) => m
            case _ => return false
        }
        return match (fields.get("base")) {
            case Some(JsonValue.String(s)) => s.size > 0
            case _ => false
        }
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
        if (kind == "ask") {
            // 提问不能在这里直接调 sink.ask（它要发 input_request，必须由回合线程做）：
            // 登记到 slot，回合线程下一拍取走并上报。
            match (this.parseAsk(text)) {
                case Some(ev) =>
                    synchronized(this.lock) {
                        match (this.slots.get(sessionId)) {
                            case Some(s) => s.askEvent = Some(ev)
                            case None => ()
                        }
                    }
                case None => eprintln("[harness-plugin] 坏 ask 载荷：" + text)
            }
            return
        }
        if (kind == "outcome") {
            // 终态必须排在所有增量之后：先把攒着的冲掉
            match (this.takeBatch(sessionId)) {
                case Some(b) => this.deliver(b)
                case None => ()
            }
            synchronized(this.lock) {
                match (this.slots.get(sessionId)) {
                    case Some(slot) =>
                        slot.outcome = Some(text)
                        slot.sink = None
                    case None => ()
                }
            }
            return
        }
        if (this.batchMs > 0 && isBufferedKind(kind)) {
            // 高频片段：攒着，等窗口到期或攒满字节数再成批交付
            let _ = this.bufferEvent(sessionId, kind, text)
            return
        }
        // 控制性事件（工具调用/产物等）：先冲掉攒着的，保证输出顺序
        match (this.takeBatch(sessionId)) {
            case Some(b) => this.deliver(b)
            case None => ()
        }
        match (sinkOpt) {
            case Some(sink) => this.dispatchContent(sink, kind, text)
            case None => ()
        }
    }

    // 解析插件上报的提问载荷：{requestId, askKind, prompt, options:[{id,label}]}
    private func parseAsk(text: String): Option<AskEvent> {
        let v = try {
            JsonValue.fromJson(JsonReader(ByteBuffer(text.toArray())))
        } catch (e: Exception) {
            return None
        }
        let fields = match (v) {
            case JsonValue.Map(m) => m
            case _ => return None
        }
        let rid = asString(fields.get("requestId") ?? JsonValue.Null)
        if (rid.size == 0) {
            return None
        }
        let opts = ArrayList<(String, String)>()
        match (fields.get("options") ?? JsonValue.Null) {
            case JsonValue.Array(arr) =>
                for (item in arr) {
                    match (item) {
                        case JsonValue.Map(o) =>
                            let id = asString(o.get("id") ?? JsonValue.Null)
                            let label = asString(o.get("label") ?? JsonValue.Null)
                            opts.add((id, label))
                        case _ => ()
                    }
                }
            case _ => ()
        }
        return Some(AskEvent(rid, asString(fields.get("askKind") ?? JsonValue.Null),
            asString(fields.get("prompt") ?? JsonValue.Null), opts.toArray()))
    }

    // 解析产物载荷：{filename, data(base64)}
    private func parseFile(text: String): Option<(String, Array<UInt8>)> {
        let v = try {
            JsonValue.fromJson(JsonReader(ByteBuffer(text.toArray())))
        } catch (e: Exception) {
            return None
        }
        let fields = match (v) {
            case JsonValue.Map(m) => m
            case _ => return None
        }
        let name = asString(fields.get("filename") ?? JsonValue.Null)
        let b64 = asString(fields.get("data") ?? JsonValue.Null)
        let bytes = match (fromBase64String(b64)) {
            case Some(b) => b
            case None => return None
        }
        return Some((name, bytes))
    }

    // 攒一条片段；攒满 FLUSH_BYTES 立刻冲一次（不持锁调用 sink）
    private func bufferEvent(sessionId: String, kind: String, text: String): Bool {
        var buffered = false
        var shouldFlush = false
        synchronized(this.lock) {
            match (this.slots.get(sessionId)) {
                case Some(slot) =>
                    if (slot.pending.size == 0) {
                        slot.lastFlushMs = nowMillis()
                    }
                    slot.pending.add((kind, text))
                    slot.pendingBytes = slot.pendingBytes + Int64(text.size)
                    buffered = true
                    shouldFlush = slot.pendingBytes >= FLUSH_BYTES
                case None => ()
            }
        }
        if (shouldFlush) {
            match (this.takeBatch(sessionId)) {
                case Some(b) => this.deliver(b)
                case None => ()
            }
        }
        return buffered
    }

    // 把该会话攒着的片段取出来（拿走即清空）。锁内只搬数据，交付在锁外。
    private func takeBatch(sessionId: String): Option<PendingBatch> {
        let (sink, items): (Option<TurnSink>, Array<(String, String)>) = synchronized(this.lock) {
            match (this.slots.get(sessionId)) {
                case Some(slot) =>
                    if (slot.pending.size == 0) {
                        (slot.sink, Array<(String, String)>())
                    } else {
                        let copy = ArrayList<(String, String)>(slot.pending)
                        slot.pending.clear()
                        slot.pendingBytes = 0
                        slot.lastFlushMs = nowMillis()
                        (slot.sink, copy.toArray())
                    }
                case None => (None, Array<(String, String)>())
            }
        }
        if (items.size == 0) {
            return None
        }
        return Some(PendingBatch(sink, items))
    }

    private func deliver(batch: PendingBatch): Unit {
        match (batch.sink) {
            case Some(sink) =>
                // 合并相邻同类型片段：批量窗口内攒的 20 个 token 应该是 1 个 delta，
                // 不是 20 次调用（后者对 UHP 的事件通道没有任何改善）。
                var curKind = ""
                var curText = ""
                for ((kind, text) in batch.items) {
                    if (kind != curKind && curText.size > 0) {
                        this.dispatchContent(sink, curKind, curText)
                        curText = ""
                    }
                    curKind = kind
                    curText = curText + text
                }
                if (curText.size > 0) {
                    this.dispatchContent(sink, curKind, curText)
                }
            case None => ()
        }
    }

    // 立刻冲刷某个会话攒着的片段（回合收口 / 提问前 / 出错前都要调）
    private func flushSession(sessionId: String): Unit {
        match (this.takeBatch(sessionId)) {
            case Some(b) => this.deliver(b)
            case None => ()
        }
    }

    // 到窗口就冲：每 10ms 扫一遍，早于 batchMs 未冲的批次取出来交付
    private func flushStale(): Unit {
        let due = ArrayList<String>()
        synchronized(this.lock) {
            let now = nowMillis()
            for ((sid, slot) in this.slots) {
                if (slot.pending.size > 0 && now - slot.lastFlushMs >= this.batchMs) {
                    due.add(sid)
                }
            }
        }
        for (sid in due) {
            match (this.takeBatch(sid)) {
                case Some(b) => this.deliver(b)
                case None => ()
            }
        }
    }

    // 冲刷线程：一个驱动一条，懒启动（只有开启批量时才起）
    private func ensureFlusher(): Unit {
        if (this.batchMs <= 0) {
            return
        }
        var start = false
        synchronized(this.lock) {
            if (!this.flusherOn) {
                this.flusherOn = true
                start = true
            }
        }
        if (!start) {
            return
        }
        let self = this
        spawn {
            while (true) {
                sleep(Duration.millisecond * 10)
                self.flushStale()
            }
        }
    }

    // 交付一条内容事件（批量与直发共用）；outcome 在 onEventLine 里单独处理
    private func dispatchContent(sink: TurnSink, kind: String, text: String): Unit {
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
                match (this.parseFile(text)) {
                    case Some((name, bytes)) => sink.producedFile(name, bytes)
                    case None => eprintln("[harness-plugin] 坏 file 载荷")
                }
            case "ask_unsupported" =>
                eprintln("[harness-plugin] 插件侧发起提问但跨进程问答未实现：" + text)
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
    if (s.startsWith("INVOKE-ERROR:")) {
        // 插件侧抛了异常：cordis 把它包成字符串回给宿主
        return TurnOutcome.Failed("harness_error", "插件调用失败：" + s["INVOKE-ERROR:".size..s.size])
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
