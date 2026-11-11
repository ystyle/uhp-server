# uhp-server

把多个 harness（opencode、dsh、pi 这类 agent）统一成一个 **UHP 端点**的常驻服务。

客户端（例如常驻助手）只面对一个 base URL：用 `GET /v1/harnesses` 看有哪些 harness，
用 `POST /v1/responses` 按 `metadata.harness_id` 派任务，用 SSE 收流、用两轮问答回答审批。
协议本身见 [UHP 2026-10-19](https://atomgit.com/ystyle/uhp)。

## 特性

- **一个端点多个 harness**：`Engine` 里注册 N 个 harness，协议面按 `harness_id` 路由；
  各自用「适配器」接：`scripted`（自检，不接模型）/ `opencode`（opencode serve 的 HTTP API）/ `acp`（任何 ACP agent：dsh、pi-acp、opencode acp…）
- **配置即部署清单**：一份 TOML 声明 token 与 harness，启动时严格校验（未知 kind/缺字段/重复 id 直接失败）
- **完整 UHP 协议面**（Conformance `full`）：响应/会话/事件流/取消/文件与产物/记忆等由 SDK 提供
- **适配器可进程隔离**（P1）：`isolate = true` 时适配器跑在独立插件进程里（cordis-cj 托管），
  一个 harness 崩了只丢这一路；插件进程随 harness 卸载被回收
- **单二进制**：Cangjie 运行时静态链入，镜像只需 glibc + libstdc++
- **无模型也能自检**：`kind = "scripted"` 的 harness 让部署验证不依赖任何凭据

## 快速开始

```bash
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 8
cp config/uhp-server.example.toml uhp-server.toml   # 改端口/token/harness
./target/release/bin/uhp_server --config uhp-server.toml
```

自检（scripted harness，不需要模型）：

```bash
curl -s http://127.0.0.1:8488/v1/uhp                       # discovery（免鉴权）
curl -s -H 'Authorization: Bearer dev-token' http://127.0.0.1:8488/v1/harnesses
curl -s -H 'Authorization: Bearer dev-token' -H 'UHP-Version: 2026-10-19' \
  -H 'Content-Type: application/json' -d '{"input":"hi","metadata":{"harness_id":"echo"}}' \
  http://127.0.0.1:8488/v1/responses
```

一键部署：

```bash
bash scripts/build.sh
docker compose up -d --build          # 挂 ./config/uhp-server.toml，暴露 8488
```

真实链路段冒烟（接一个真 agent，默认本机 opencode）：

```bash
bash scripts/real-smoke.sh                              # opencode acp
AGENT_CMD="dsh --profile acp" bash scripts/real-smoke.sh # 换成 dsh
AGENT_CMD="openma-pi-acp" bash scripts/real-smoke.sh     # 换成 pi
```

> Docker 采用「宿主/CI 产出二进制 → 镜像只打包」的策略（与其他仓颉项目一致）：
> 二进制为静态运行时，运行镜像只需 `archlinux` 的 glibc/gcc-libs。

## 配置

完整样例见 [`config/uhp-server.example.toml`](config/uhp-server.example.toml)。

| 段 | 字段 | 说明 |
|---|---|---|
| `[server]` | `bind` / `port` | 监听地址（默认 `127.0.0.1:8488`）；对外提供服务时配 `0.0.0.0` |
| `[server]` | `session_ttl_seconds` | 空闲会话存活秒数，`0` = 不回收（默认）；长跑部署建议开（如 `1800`） |
| `[[tokens]]` | `token` / `principal` | 客户端凭证；一个客户端一个 token |
| `[[harnesses]]` | `id` / `name` / `base` / `kind` / `default_model` / `enabled` | harness 身份与类型 |
| `kind = "acp"` | `command` / `args` / `cwd` / `session_mode` / `timeout_seconds` / `permission_timeout_seconds` | 拉起的 ACP agent；`session_mode = serial \| parallel` |
| `kind = "opencode"` | `base_url` / `directory` / `user` / `password` / `model_provider` / `model_id` | 连一个 `opencode serve` |
| `kind = "scripted"` | `reply` / `delay_ms` | 自检用，按固定文本返回 |
| 任一 kind | `isolate` / `plugin_path` | `isolate = true` 时该 harness 的适配器跑在独立插件进程里（cordis 托管）；`plugin_path` 缺省取 host 同目录的 `uhp_server.plugin` |

## 文档

- 设计（装配、进程模型、P0/P1 路线）：[docs/design.md](docs/design.md)
- 各 harness 的 ACP 能力矩阵：[uhp-acp/docs/support.md](https://atomgit.com/ystyle/uhp/blob/master/uhp-acp/docs/support.md)
- 协议与 SDK：[uhp](https://atomgit.com/ystyle/uhp)

## 状态

P0：单进程 host（适配器在 host 进程内）+ 配置 + 单二进制 + Docker；**cordis-cj 托管适配器插件是 P1**。

## 许可证

MulanPSL-2.0。
