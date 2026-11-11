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
- **自己写适配器不用改本仓**：实现一个几十行的插件进程（协议见
  [docs/writing-a-harness.md](docs/writing-a-harness.md)），写进配置就能和其它 harness 一起跑

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

一键部署（本地构建）：

```bash
bash scripts/make-dist.sh                            # 编译 + 收集 dist/（镜像上下文只要它）
cp config/uhp-server.example.toml config/uhp-server.toml
docker compose up -d --build                         # 挂 ./config/uhp-server.toml，暴露 8488
```

用发布镜像（免构建）：

```bash
docker pull ghcr.io/ystyle/uhp-server:latest
docker run --rm -p 8488:8488 -v "$PWD/config/uhp-server.toml:/app/uhp-server.toml:ro" \
  ghcr.io/ystyle/uhp-server:latest
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
| `[server]` | `event_batch_ms` | 增量批量窗口（默认 `25`）：插件进程上报的高频片段先攒后合并成批下发；`0` = 关闭 |
| `[[tokens]]` | `token` / `principal` | 客户端凭证；一个客户端一个 token |
| `[[harnesses]]` | `id` / `name` / `base` / `kind` / `default_model` / `enabled` | harness 身份与类型 |
| `kind = "acp"` | `command` / `args` / `cwd` / `session_mode` / `timeout_seconds` / `permission_timeout_seconds` | 拉起的 ACP agent；`session_mode = serial \| parallel` |
| `kind = "opencode"` | `base_url` / `directory` / `user` / `password` / `model_provider` / `model_id` | 连一个 `opencode serve` |
| `kind = "scripted"` | `reply` / `delay_ms` | 自检用，按固定文本返回 |
| 任一 kind | `isolate` / `plugin_path` | `isolate = true` 时该 harness 的适配器跑在独立插件进程里（cordis 托管）；`plugin_path` 缺省取 host 同目录的 `uhp_server.plugin` |
| 任一 kind | `plugin_args` | 自写插件的参数，**原样**传给插件（`args` 是给 ACP agent 的，会被包成 `--arg`） |

## 自己写适配器

想接一个本仓没有的 agent，有两种做法，推荐第一种——**不用改 uhp-server 一行代码**：

1. **写一个插件进程**：几十行的可执行文件，提供 `harness` 服务（`info`/`run`/`cancel`/`answer`/`closeSession`），
   增量按约定写成 stderr 上的 `#UHP#{…}` 行；配置里 `isolate = true` + `plugin_path` 指过去即可。
2. **写一个进程内驱动**：实现 SDK 的 `HarnessDriver`，在 `src/factory.cj` 加一个 kind（要和 host 同生共死时用）。

完整流程、协议表、自查清单、常见故障对照：[**docs/writing-a-harness.md**](docs/writing-a-harness.md)。
可运行的参照实现：[src/examples/echo_plugin/main.cj](src/examples/echo_plugin/main.cj)——它被
`src/echo_plugin_test.cj` 端到端跑过（配置片段与文档逐字一致）。

## 发布

本仓是产品，**不发中心仓**。推 tag（`v0.1.1`）触发 GitHub Actions：

- `artifacts`：构建二进制包（`uhp_server` + `uhp_server.plugin` + 配置样例 + README/LICENSE）→ GitHub Release
- `container`：构建镜像 → `ghcr.io/ystyle/uhp-server:v<版本>` 与 `:latest`

流程与两个镜像坑（PID 1 信号、构建上下文）见 [docs/RELEASE.md](docs/RELEASE.md)。

## 文档

- **发布与镜像**：[docs/RELEASE.md](docs/RELEASE.md)
- **自己写适配器（插件进程 / 进程内驱动）**：[docs/writing-a-harness.md](docs/writing-a-harness.md)
- 设计（装配、进程模型、P0/P1 路线）：[docs/design.md](docs/design.md)
- 各 harness 的 ACP 能力矩阵：[uhp-acp/docs/support.md](https://atomgit.com/ystyle/uhp/blob/master/uhp-acp/docs/support.md)
- 协议与 SDK：[uhp](https://atomgit.com/ystyle/uhp)

## 状态

P0 已完成：单进程 host + 配置 + 单二进制 + Docker。
P1 已完成：cordis-cj 托管适配器插件（进程隔离、跨进程流式增量、两轮问答、产物字节、崩溃感知）。
剩增量批量化这一项性能优化，之后进发布（tag + 二进制 + 镜像）。

## 许可证

MulanPSL-2.0。
