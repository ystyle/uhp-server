// 配置模型与加载：TOML（tomlcj + stdx.serialization），与手工拼 JSON 无关。
//
// 配置即部署清单：一个 [[tokens]] 一条客户端凭证，一个 [[harnesses]] 一个 harness。
// 解析严格在启动时完成：字段缺失/取值非法一律 fail fast，不带病运行。
package uhp_server

import std.collection.{ArrayList, HashMap}
import std.fs.{File, OpenMode}
import std.io.ByteBuffer
import stdx.serialization.serialization.*
import tomlcj.*

public class ServerConfigError <: Exception {
    public init(msg: String) {
        super(msg)
    }
}

// ---------- 小工具：DataModel 的宽容读取 ----------

func asStruct(dm: DataModel, what: String): DataModelStruct {
    match (dm) {
        case s: DataModelStruct => return s
        case _ => throw ServerConfigError(what + "：期望 table")
    }
}

func stringOr(dms: DataModelStruct, key: String, dflt: String): String {
    return match (dms.get(key)) {
        case v: DataModelString => v.getValue()
        case _ => dflt
    }
}

func intOr(dms: DataModelStruct, key: String, dflt: Int64): Int64 {
    return match (dms.get(key)) {
        case v: DataModelInt => v.getValue()
        case _ => dflt
    }
}

func boolOr(dms: DataModelStruct, key: String, dflt: Bool): Bool {
    return match (dms.get(key)) {
        case v: DataModelBool => v.getValue()
        case _ => dflt
    }
}

func stringsOr(dms: DataModelStruct, key: String): ArrayList<String> {
    let out = ArrayList<String>()
    match (dms.get(key)) {
        case seq: DataModelSeq =>
            for (item in seq.getItems()) {
                match (item) {
                    case s: DataModelString => out.add(s.getValue())
                    case _ => ()
                }
            }
        case _ => ()
    }
    return out
}

public class ServerSection <: Serializable<ServerSection> {
    public var bind: String = "127.0.0.1"
    public var port: Int64 = 8488
    // harness 插件进程的通信方式：stdio（默认，逐行 JSON）| uds（Unix socket + Content-Length 帧）。
    // UDS 少了逐行 framing 与管道缓冲，控制面大负载更稳；stdio 不依赖文件系统权限，容器里更省事。
    public var plugin_transport: String = "stdio"
    // 增量批量窗口（毫秒）：插件进程上报的 text/reasoning/tool_args 片段先攒再成批交给 UHP 的事件通道。
    // 0 = 关闭（每条都立即转发）。默认 25ms：保留「渐进」观感，又把 sink 调用次数降一个量级。
    public var event_batch_ms: Int64 = 25
    // 空闲会话的存活秒数：0 = 不回收（默认）。长跑部署建议开（如 1800）。
    // UHP 协议没有删除会话的端点，会话什么时候消失由宿主决定，这里就是那个决定。
    public var session_ttl_seconds: Int64 = 0
    public init() {}
    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<String>("bind", this.bind))
            .add(field<Int64>("port", this.port))
            .add(field<String>("plugin_transport", this.plugin_transport))
            .add(field<Int64>("event_batch_ms", this.event_batch_ms))
            .add(field<Int64>("session_ttl_seconds", this.session_ttl_seconds))
    }
    public static func deserialize(dm: DataModel): ServerSection {
        let dms = asStruct(dm, "server")
        let r = ServerSection()
        r.bind = stringOr(dms, "bind", r.bind)
        r.port = intOr(dms, "port", r.port)
        r.plugin_transport = stringOr(dms, "plugin_transport", r.plugin_transport)
        r.event_batch_ms = intOr(dms, "event_batch_ms", r.event_batch_ms)
        r.session_ttl_seconds = intOr(dms, "session_ttl_seconds", r.session_ttl_seconds)
        return r
    }
}

public class TokenEntry <: Serializable<TokenEntry> {
    public var token: String = ""
    public var principal: String = ""
    public init() {}
    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<String>("token", this.token))
            .add(field<String>("principal", this.principal))
    }
    public static func deserialize(dm: DataModel): TokenEntry {
        let dms = asStruct(dm, "tokens")
        let r = TokenEntry()
        r.token = stringOr(dms, "token", "")
        r.principal = stringOr(dms, "principal", "")
        return r
    }
}

// 一个 harness 的声明。字段按 kind 取用，未用的字段保持缺省。
public class HarnessSpec <: Serializable<HarnessSpec> {
    public var id: String = ""
    public var name: String = ""
    public var base: String = ""
    public var kind: String = ""
    public var default_model: String = "auto"
    public var enabled: Bool = true
    // kind = acp（任何 ACP agent：dsh / pi-acp / opencode acp …）
    public var command: String = ""
    public var args: ArrayList<String> = ArrayList<String>()
    // 自己写的插件（isolate = true 且 kind 不是内置那几种）用这个传参：宿主原样转给插件，
    // 不像 args 那样再包一层 --arg（args 是给 ACP agent 的命令行参数）。
    public var plugin_args: ArrayList<String> = ArrayList<String>()
    public var cwd: String = ""
    public var session_mode: String = "serial"
    public var timeout_seconds: Int64 = 600
    public var permission_timeout_seconds: Int64 = 600
    // kind = opencode（opencode serve 的 HTTP API）
    public var base_url: String = ""
    public var directory: String = ""
    public var user: String = "opencode"
    public var password: String = ""
    public var model_provider: String = ""
    public var model_id: String = ""
    // P1：把适配器放进独立进程（cordis 托管）。默认 false = host 进程内。
    public var isolate: Bool = false
    // 插件可执行文件路径；空 = 与 host 同目录的 uhp_server.plugin
    public var plugin_path: String = ""
    // kind = scripted（不接模型的自检 harness）
    public var reply: String = "scripted reply"
    // scripted backend 的分片数与步间延迟：用来验证流式（isolate 时生效）
    public var chunks: Int64 = 1
    // scripted backend 额外产出一个文本产物（文件名）；空 = 不产出
    public var file: String = ""
    // 产物内容字节数（> 0 时生成等长内容，用来压传输层）
    public var file_size: Int64 = 0
    public var delay_ms: Int64 = 0
    public init() {}
    public func serialize(): DataModel {
        return DataModelStruct()
            .add(field<String>("id", this.id))
            .add(field<String>("name", this.name))
            .add(field<String>("base", this.base))
            .add(field<String>("kind", this.kind))
            .add(field<String>("default_model", this.default_model))
            .add(field<Bool>("enabled", this.enabled))
            .add(field<String>("command", this.command))
            .add(field<ArrayList<String>>("args", this.args))
            .add(field<ArrayList<String>>("plugin_args", this.plugin_args))
            .add(field<String>("cwd", this.cwd))
            .add(field<String>("session_mode", this.session_mode))
            .add(field<Int64>("timeout_seconds", this.timeout_seconds))
            .add(field<Int64>("permission_timeout_seconds", this.permission_timeout_seconds))
            .add(field<String>("base_url", this.base_url))
            .add(field<String>("directory", this.directory))
            .add(field<String>("user", this.user))
            .add(field<String>("password", this.password))
            .add(field<String>("model_provider", this.model_provider))
            .add(field<String>("model_id", this.model_id))
            .add(field<Bool>("isolate", this.isolate))
            .add(field<String>("plugin_path", this.plugin_path))
            .add(field<String>("reply", this.reply))
            .add(field<Int64>("chunks", this.chunks))
            .add(field<String>("file", this.file))
            .add(field<Int64>("file_size", this.file_size))
            .add(field<Int64>("delay_ms", this.delay_ms))
    }
    public static func deserialize(dm: DataModel): HarnessSpec {
        let dms = asStruct(dm, "harnesses")
        let r = HarnessSpec()
        r.id = stringOr(dms, "id", r.id)
        r.name = stringOr(dms, "name", r.name)
        r.base = stringOr(dms, "base", r.base)
        r.kind = stringOr(dms, "kind", r.kind)
        r.default_model = stringOr(dms, "default_model", r.default_model)
        r.enabled = boolOr(dms, "enabled", r.enabled)
        r.command = stringOr(dms, "command", r.command)
        r.args = stringsOr(dms, "args")
        r.plugin_args = stringsOr(dms, "plugin_args")
        r.cwd = stringOr(dms, "cwd", r.cwd)
        r.session_mode = stringOr(dms, "session_mode", r.session_mode)
        r.timeout_seconds = intOr(dms, "timeout_seconds", r.timeout_seconds)
        r.permission_timeout_seconds = intOr(dms, "permission_timeout_seconds", r.permission_timeout_seconds)
        r.base_url = stringOr(dms, "base_url", r.base_url)
        r.directory = stringOr(dms, "directory", r.directory)
        r.user = stringOr(dms, "user", r.user)
        r.password = stringOr(dms, "password", r.password)
        r.model_provider = stringOr(dms, "model_provider", r.model_provider)
        r.model_id = stringOr(dms, "model_id", r.model_id)
        r.isolate = boolOr(dms, "isolate", r.isolate)
        r.plugin_path = stringOr(dms, "plugin_path", r.plugin_path)
        r.reply = stringOr(dms, "reply", r.reply)
        r.chunks = intOr(dms, "chunks", r.chunks)
        r.file = stringOr(dms, "file", r.file)
        r.file_size = intOr(dms, "file_size", r.file_size)
        r.delay_ms = intOr(dms, "delay_ms", r.delay_ms)
        return r
    }
}

public class ServerConfig <: Serializable<ServerConfig> {
    public var server: ServerSection = ServerSection()
    public var tokens: ArrayList<TokenEntry> = ArrayList<TokenEntry>()
    public var harnesses: ArrayList<HarnessSpec> = ArrayList<HarnessSpec>()
    public init() {}
    public func serialize(): DataModel {
        let tokensDm = ArrayList<DataModel>()
        for (t in this.tokens) { tokensDm.add(t.serialize()) }
        let harnessesDm = ArrayList<DataModel>()
        for (h in this.harnesses) { harnessesDm.add(h.serialize()) }
        return DataModelStruct()
            .add(Field("server", this.server.serialize()))
            .add(Field("tokens", DataModelSeq(tokensDm)))
            .add(Field("harnesses", DataModelSeq(harnessesDm)))
    }
    public static func deserialize(dm: DataModel): ServerConfig {
        let dms = asStruct(dm, "root")
        let r = ServerConfig()
        r.server = match (dms.get("server")) {
            case s: DataModelStruct => ServerSection.deserialize(s)
            case _ => ServerSection()
        }
        r.tokens = ArrayList<TokenEntry>()
        match (dms.get("tokens")) {
            case seq: DataModelSeq =>
                for (item in seq.getItems()) { r.tokens.add(TokenEntry.deserialize(item)) }
            case _ => ()
        }
        r.harnesses = ArrayList<HarnessSpec>()
        match (dms.get("harnesses")) {
            case seq: DataModelSeq =>
                for (item in seq.getItems()) { r.harnesses.add(HarnessSpec.deserialize(item)) }
            case _ => ()
        }
        return r
    }
}

public func loadConfig(path: String): ServerConfig {
    let file = try {
        File(path, OpenMode.Read)
    } catch (e: Exception) {
        throw ServerConfigError("读不到配置文件：" + path)
    }
    let decoder = Decoder(file)
    let dm = DataModel.fromToml(decoder.decode())
    return ServerConfig.deserialize(dm)
}

public func parseConfig(content: String): ServerConfig {
    let decoder = Decoder(ByteBuffer(content.toArray()))
    let dm = DataModel.fromToml(decoder.decode())
    return ServerConfig.deserialize(dm)
}
