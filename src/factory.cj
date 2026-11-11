// 装配：把配置里的 harness 条目变成 Engine 认识的 ConfiguredHarness。
//
// P0 的 driver 都在 host 进程内（ACP agent / opencode 服务仍各自是子进程或外部 HTTP）。
// P1 换 cordis 托管插件时，这个工厂改成按 kind 起插件进程 + CordisHarnessDriver，接口不变。
package uhp_server

import std.collection.{ArrayList, HashMap}
import uhp.server.*
import uhp_acp.*
import uhp_opencode.*

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
        let driver = buildDriver(h, label)
        out.add(ConfiguredHarness(h.id, label, base, model, driver))
    }
    if (out.size == 0) {
        throw ServerConfigError("没有启用的 harness")
    }
    return out.toArray()
}

func buildDriver(h: HarnessSpec, label: String): HarnessDriver {
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
