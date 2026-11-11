# uhp-server 设计

> 状态：P0 实现中（单进程 host）。P1（cordis-cj 托管适配器插件）见 §6。

## 1. 它是什么、不是什么

UHP 是 HTTP/1.1 + REST/JSON + SSE 的协议：客户端提交任务、收事件流、回答提问、取产物。
本仓是**服务端**的成品：一个进程、一个端口，背后挂 N 个 harness。

| 做 | 不做 |
|---|---|
| 装配 `Engine` + `UhpHttpServer`、读配置、管 token、管 harness 生命周期 | 协议实现（在 `uhp` 仓） |
| 按 `kind` 选适配器，把 harness 暴露成 `ConfiguredHarness` | agent 循环、模型调用（在 harness 自己进程里） |
| 部署产物：单二进制 / Docker / 配置样例 | 客户端逻辑（starline 等消费方自己持有） |

## 2. 进程模型（P0）

```text
uhp-server 进程（单二进制）
├── Engine（会话/响应/事件/文件/记忆，全内存）
├── UhpHttpServer（一个端口，Bearer token）
└── 适配器（进程内对象）
    ├── ACP driver ──spawn──▶ dsh / pi-acp / opencode acp（子进程）
    ├── opencode driver ──HTTP──▶ 已运行的 opencode serve
    └── scripted driver（自检，不接模型）
```

为什么 P0 不拆进程：

- 协议面与装配先跑通是当前风险最大的部分；适配器本身很薄，真正危险/重的 agent 已经在自己的子进程里；
- 单二进制让 Docker/部署最简单，用户不需要理解插件拓扑；
- P1 拆成 cordis 插件时，**协议面与配置语义不变**，只换宿主实现（见 §6）。

## 3. 装配流程

```text
读 TOML ──▶ ServerConfig ──▶ buildHarnesses() ──▶ Engine(..., cls: Full)
                                │                     │
                   kind=acp/opencode/scripted      UhpHttpServer(Authenticator(tokens))
                                │                     │
                            HarnessDriver        ServerBuilder(bind, port).serve()
```

- **fail fast**：未知 `kind`、缺 `command`/`base_url`、重复 `id`、空 tokens → 启动失败；
- 适配器构造是惰性的：ACP 在第一个任务时才拉起子进程（启动快，且不因后端暂时不在而拒绝启动）；
- `cls: Full`：能力声明与实现一致（files/sessions/input_requests/memories 等都开了）。

## 4. 会话与回收

UHP 规范**没有** `DELETE /v1/sessions/{id}`：会话由服务端持有、按自己的策略回收。

约定：

- 会话与响应都在内存；**重启即丢**（协议不要求持久化）。客户端按 404/新会话处理；
- 会话内同时只允许一个进行中的响应（协议要求，第二个 409 `session_busy`）；并发靠多会话；
- **会话 TTL 驱逐**（`session_ttl_seconds`，默认关）：后台线程按 `min(ttl, 30s)` 的间隔调
  `Engine.reapIdleSessions`，收掉空闲且没有回合在跑的会话，并触发 driver 的 `closeSession()`。
  这是长跑部署必须开的一项——否则会话记录与 agent 侧上下文只增不减。
- 退出：`serve()` 返回后调 `Engine.close()` 收子进程/连接。Cangjie 没有信号注册接口，
  SIGTERM 会直接结束进程；此时靠「父进程退出 → 子进程 stdin EOF → agent 自行退出」兜底
  （dsh / pi-acp / opencode acp 实测都会）。

## 5. 鉴权与网络

- `[[tokens]]`：`token` → `principal`；请求必须 `Authorization: Bearer <token>`；
- 跨 principal 访问一律 404（协议要求，不泄露存在性）；
- 默认只监听 `127.0.0.1`：本机客户端（starline 等）直连即可；对外时改 `0.0.0.0` 并在前面加 TLS/反代，
  此时务必给每个客户端独立 token。

## 6. P1：cordis-cj 托管适配器插件

目标：适配器从 host 进程内移到独立插件进程（进程隔离 / 热卸载 / 崩溃自愈），协议面与配置不变。

```text
uhp-server（host）
├── Engine + UhpHttpServer
├── cordis host（按 uhp-server.toml 的 harness 列表拉起/重启插件进程）
└── CordisHarnessDriver（把 HarnessDriver SPI 代理到插件 RPC）
        │ stdio/UDS JSON-RPC（cordis-cj）
        ▼
  harness 插件进程（内嵌 uhp-acp / uhp-opencode）
```

要点：

1. 插件暴露 `harness` 服务：`info` / `run` / `cancel` / `closeSession`；卸载 → `driver.close()`。
2. `run` 的流式增量（text/reasoning/toolCall/diff）是**高频事件**，必须按 20–50ms 或若干 KB 批量上行，
   不能一个 token 一次 IPC（cordis-cj 的设计目标本身是中低频控制面）。
3. 取消：host `cancel` → 插件置 `CancelToken`；完成：`run` 的 RPC 返回 `TurnOutcome`。
4. `Engine` 的 harness 注册表目前是构造时固定的 → P1 需要 `addHarness/removeHarness`（或插件变更时重启 host，先不做）。

## 7. 与 `uhp` SDK 的待办（记在这里，别散落）

| 项 | 状态 | 落地内容 |
|---|---|---|
| 可选生命周期接口 `close()/closeSession()` | ✅ 已进 SDK（`44eaf6a`） | `HarnessLifecycle`：`close()` / `closeSession(sessionId)`；Engine 只对实现了的 driver 调用 |
| 动态 harness 注册 | ✅ 已进 SDK | `Engine.addHarness` / `removeHarness`（有会话绑定则拒绝）+ `releaseSession` / `close` |
| 客户端补齐 sessions/files/input_response | ✅ 已进 SDK | `sessions` / `getSession` / `sessionTurns` / `sessionFiles` / `downloadFile`（字节）/ `answerInput` / `answerInputStream` |

本仓的后续接入（P2）：
- 会话 TTL 驱逐时调 `Engine.releaseSession`（现在按需手动）；
- 退出路径调 `Engine.close()`。当前没有信号处理，靠「父进程退出 → 子进程 stdin EOF → agent 自行退出」兜底，
  接 signal 之后再补。

## 8. 发布

- 本仓是产品：打 tag + 出二进制包 + 出 Docker 镜像；**不发中心仓**。
- 依赖切换：开发期 `cjpm.toml` 用 path 依赖（同工作区 `../uhp/*`）；对外构建时换成中心仓精确版本：
  `uhp = "0.1.x"` / `uhp_acp = "0.1.x"` / `uhp_opencode = "0.1.x"`，并在这里维护兼容表。
- 兼容表（发布时更新）：

| uhp-server | uhp | uhp-acp / uhp-opencode | 备注 |
|---|---|---|---|
| 0.1.x（开发） | path @ `44eaf6a` | path | 需要 `uhp` 0.1.1（含生命周期/动态 harness/客户端补齐，待发布） |
