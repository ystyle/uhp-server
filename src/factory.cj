// 装配：把配置里的 harness 条目变成 Engine 认识的 ConfiguredHarness。
//
// P0 的 driver 都在 host 进程内（ACP agent / opencode 服务仍各自是子进程或外部 HTTP）。
// P1 换 cordis 托管插件时，这个工厂改成按 kind 起插件进程 + CordisHarnessDriver，接口不变。
package uhp_server

import std.collection.{ArrayList, HashMap}
import std.env.getCommandLine
import std.fs.Path
import uhp.server.*
import uhp_acp.*
import uhp_opencode.*

// 当前可执行文件所在目录（用来找同目录的插件二进制）。
// argv[0] 可能是相对路径，所以只取目录部分，不做 realpath 猜测。
func currentExecutableDir(): String {
    let argv = getCommandLine()
    let exe = if (argv.size > 0) { argv[0] } else { "" }
    // lastIndexOf 返回 Option：没有 '/' 说明是裸文件名，没有目录可拼
    let idx = match (exe.lastIndexOf("/")) {
        case Some(v) => v
        case None => -1
    }
    if (idx <= 0) {
        return "."
    }
    return exe[0..idx]
}

func defaultBase(kind: String): String {
    return match (kind) {
        case "acp" => "acp"
        case "opencode" => "opencode"
        case "scripted" => "scripted"
        case _ => kind
    }
}

// 未知 kind、缺必填字段、id 重复 → 启动即失败（配置错误不该等到第一个任务才暴露）
public func buildHarnesses(cfg: ServerConfig): Array<ConfiguredHarness> {
    if (cfg.harnesses.size == 0) {
        throw ServerConfigError("至少要配一个 [[harnesses]]")
    }
    let out = ArrayList<ConfiguredHarness>()
    let seen = HashMap<String, Bool>()
    for (h in cfg.harnesses) {
        if (!h.enabled) {
            continue
        }
        if (h.id.size == 0) {
            throw ServerConfigError("[[harnesses]] 缺 id")
        }
        if (seen.contains(h.id)) {
            throw ServerConfigError("harness id 重复：" + h.id)
        }
        seen[h.id] = true
        let label = if (h.name.size > 0) { h.name } else { h.id }
        let base = if (h.base.size > 0) { h.base } else { defaultBase(h.kind) }
        let model = if (h.default_model.size > 0) { h.default_model } else { "auto" }
        let transport = match (cfg.server.plugin_transport) {
            case "stdio" => "stdio"
            case "uds" => "uds"
            case other => throw ServerConfigError("[server] plugin_transport 只能是 stdio / uds，实际 " + other)
        }
        let driver = buildDriver(h, label, cfg.server.event_batch_ms, transport)
        out.add(ConfiguredHarness(h.id, label, base, model, driver))
    }
    if (out.size == 0) {
        throw ServerConfigError("没有启用的 harness")
    }
    return out.toArray()
}

// 插件可执行文件：显式配了就用配的，否则取 host 同目录的 uhp_server.plugin
func pluginBinary(h: HarnessSpec): String {
    if (h.plugin_path.size > 0) {
        return h.plugin_path
    }
    return currentExecutableDir() + "/uhp_server.plugin"
}

// 把一个 harness 规格翻译成插件进程参数（见 src/plugin/main.cj 的 parseArgs）
func pluginArgsOf(h: HarnessSpec): Array<String> {
    let out = ArrayList<String>()
    out.add("--backend")
    out.add(h.kind)
    if (h.kind == "scripted") {
        out.add("--reply")
        out.add(h.reply)
        out.add("--chunks")
        out.add(h.chunks.toString())
        out.add("--delay-ms")
        out.add(h.delay_ms.toString())
        if (h.file.size > 0) {
            out.add("--file")
            out.add(h.file)
            out.add("--file-size")
            out.add(h.file_size.toString())
        }
    }
    if (h.command.size > 0) {
        out.add("--command")
        out.add(h.command)
    }
    if (h.cwd.size > 0) {
        out.add("--cwd")
        out.add(h.cwd)
    }
    out.add("--session-mode")
    out.add(h.session_mode)
    out.add("--timeout")
    out.add(h.timeout_seconds.toString())
    for (a in h.args) {
        out.add("--arg")
        out.add(a)
    }
    // 自写插件的参数原样传：宿主不解释它们的含义
    for (a in h.plugin_args) {
        out.add(a)
    }
    return out.toArray()
}

func buildDriver(h: HarnessSpec, label: String, batchMs: Int64, transport: String): HarnessDriver {
    if (h.isolate) {
        return CordisHarnessDriver(pluginBinary(h), pluginArgsOf(h), defaultBase(h.kind), label,
            timeoutSeconds: h.timeout_seconds, batchMs: batchMs, transport: transport)
    }
    match (h.kind) {
        case "scripted" =>
            let steps: Array<ScriptStep> = [ScriptStep.Text(h.reply)]
            return ScriptedHarness(steps, TurnOutcome.Completed(None), delayMillis: h.delay_ms)
        case "acp" =>
            if (h.command.size == 0) {
                throw ServerConfigError("harness " + h.id + "：kind=acp 需要 command")
            }
            let mode = match (h.session_mode) {
                case "parallel" => AcpSessionMode.Parallel
                case "serial" => AcpSessionMode.Serial
                case other => throw ServerConfigError("harness " + h.id + "：session_mode 只能是 serial / parallel，实际 " + other)
            }
            let cwd = if (h.cwd.size > 0) { h.cwd } else { "/tmp" }
            return AcpDriver(AcpOptions(h.command, args: h.args.toArray(), cwd: cwd, label: label,
                timeoutSeconds: h.timeout_seconds, permissionTimeoutSeconds: h.permission_timeout_seconds,
                sessionMode: mode))
        case "opencode" =>
            if (h.base_url.size == 0) {
                throw ServerConfigError("harness " + h.id + "：kind=opencode 需要 base_url")
            }
            let dir = if (h.directory.size > 0) { h.directory } else { "/tmp" }
            let model: Option<(String, String)> = if (h.model_id.size > 0 && h.model_provider.size > 0) {
                Some((h.model_id, h.model_provider))
            } else {
                None
            }
            return OpencodeDriver(OpencodeOptions(h.base_url, dir, user: h.user, password: h.password,
                model: model, timeoutSeconds: h.timeout_seconds, label: label))
        case _ =>
            throw ServerConfigError("harness " + h.id + "：未知 kind「" + h.kind + "」（支持 acp / opencode / scripted）")
    }
}
