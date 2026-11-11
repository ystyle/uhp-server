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
- 退出：`src/shutdown.cj` 用 `std.runtime.registerSignalHandler` 注册 SIGTERM/SIGINT，
  处理器只置位（信号上下文不能阻塞），后台线程做收尾：停 HTTP（`serve()` 返回）→ `Engine.close()`
  （关 agent 子进程/插件进程）→ main 自然退出 `exit 0`。`std.env.atExit` 作为正常退出路径的兜底。
  **必须有处理器**：容器里 PID 1 对没有处理器的信号一律忽略，实测没有它时 `docker stop` 要等满
  10s 宽限后被 SIGKILL（exit 137）；有了它 0.2s、exit 0。

## 5. 鉴权与网络

- `[[tokens]]`：`token` → `principal`；请求必须 `Authorization: Bearer <token>`；
- 跨 principal 访问一律 404（协议要求，不泄露存在性）；
- 默认只监听 `127.0.0.1`：本机客户端（starline 等）直连即可；对外时改 `0.0.0.0` 并在前面加 TLS/反代，
  此时务必给每个客户端独立 token。

## 6. P1：cordis-cj 托管适配器插件

目标：适配器从 host 进程内移到独立插件进程（进程隔离 / 崩溃只丢一路 / 卸载即回收），协议面与配置不变。

> 怎么**自己写一个适配器**（插件进程 / 进程内驱动）见 [writing-a-harness.md](writing-a-harness.md)；
> 可运行的参照实现是 [src/examples/echo_plugin/main.cj](../src/examples/echo_plugin/main.cj)。

```text
uhp-server（host）
├── Engine + UhpHttpServer
├── PluginHost（cordis_host）：拉起 / 握手 / stderr 转发 / 终止回收
└── CordisHarnessDriver（把 HarnessDriver SPI 代理成对插件的 invoke）
        │ stdio JSON-RPC（cordis 的 initialize/provide/invoke）
        ▼
  uhp_server.plugin 进程（插件内嵌 uhp-acp / uhp-opencode / scripted）
```

**已落地（P1-a）**：`isolate = true` 的 harness 走插件进程；插件暴露 `harness` 服务的
`info` / `run` / `cancel` / `closeSession`；`close()` 经 `host.removePlugin` 终止进程。
端到端测试：`src/plugin_test.cj`（scripted backend，不需要模型）。

已完成（P1-a + P1-b 流式）：

| 项 | 现状 |
|---|---|
| 回合执行 | `run` 的 invoke **持续整个回合**；插件在自己的处理线程上跑驱动并逐条上报，宿主另起线程等结果 |
| 增量上行 | 插件把每条增量写成 **stderr 上的 JSON 行**（`#UHP#{"ev":"harness","sid":…,"kind":…,"text":…}`），宿主 `PluginManager` 的 stderr 转发回调里解析 → `TurnSink` |
| 工具调用 | `tool_call` / `tool_result` / `tool_args` / `degrade` 逐条映射（字段用 U+001F 分隔） |
| 启动等待 | invoke 前必须 `awaitActive`（插件还在 `initialize` 时服务表是空的，invoke 会回 INVOKE-ERROR） |
| 会话/进程回收 | `closeSession` → 插件内驱动；`close()` → `removePlugin` 终止进程 |

**为什么数据面走 stderr 而不是 cordis 事件**：实测把 `ctx.emit` 放进回合执行线程连续上报，
首帧之后插件连接就被打断（接收/写路径不是线程无关的）。stderr 由宿主逐行转发，
天然串行、不占协议通道，控制面（invoke）与数据面（增量）也顺带分开了。

**传输方式**（`[server] plugin_transport`，两种都实测过）：

| 值 | 机制 | 说明 |
|---|---|---|
| `stdio`（默认） | 管道 + 逐行 JSON 帧 | 不依赖文件系统，容器里最省事 |
| `uds` | unix socket + Content-Length 帧 | 宿主 listen、插件连；路径有 ~108 字节上限，故用短名 `/tmp/uhp-h-<ms>.sock`，退出时删除 |

**就绪判据**：cordis 的插件启动顺序是「先 provide 再跑 handler」，宿主拿到 provide 时
插件的 `ctx.registerHandler` 可能还没执行——此刻 invoke 会被回成
`INVOKE-ERROR: service 'harness' not provided by this plugin`（实测偶发，表现为回合随机失败）。

- cordis 现在提供 `ready` 通知 + `PluginHost.awaitReady()`（= Active 且 handler 已执行完），
  `ensurePlugin` 用它作为「可以 invoke」的判据；
- 再补一道结构校验：`info` 必须返回**带 base 的对象**——cordis 会把插件侧异常包成字符串回包，
  「有回包」≠「服务可用」；
- `decodeOutcome` 把 `INVOKE-ERROR:` 前缀单独映射成失败原因，不落进「未知终态」。

跨进程问答（P1-c 已完成）：

```text
插件：sink.ask() 登记 requestId → 上报 kind=ask → 挂起等答案
宿主：onEventLine 把 ask 落进 slot → 回合线程取走调 TurnSink.ask()（发 input_request）
      → 本轮以 incomplete(input_required) 收口，并把「插件 requestId ↔ 会话」记进 pendingAsks
下一轮：run(ctx) 带 answers → 宿主用 answer 方法把答案送回插件 → 插件那条 run invoke 继续跑完
```

要点：**不重新发起回合**（插件里驱动还挂在 ask 上，重发会开两条回合）；
答案按 requestId 校验（迟到的旧答案喂不进新提问）；
事件在 stderr 线程收，`sink.ask` 必须由回合线程调，所以中间隔一层 slot 交接。

产物与崩溃（P1-c 已完成）：

| 项 | 做法 |
|---|---|
| 产物字节 | 插件把 `producedFile` 的字节 base64 后随 `file` 事件上报，宿主解码再交给 `TurnSink`；测试断言「插件里产生的字节 == 客户端下载到的字节」 |
| 崩溃感知 | 回合循环每拍查 `PluginManager.isExited`，插件进程没了立即 `failed` 并把 instance 清空（下次 run 重新拉起），不再干等超时；测试用 SIGKILL 后端钉住「快速失败」 |

> 踩坑记录：插件里想"让进程死掉"不能用 `std.env.exit`——它走优雅关闭，要等 RPC 线程收尾，
> 在 handler 线程里调会把进程卡住而不是退出。要模拟崩溃得直接 `SIGKILL` 自己。

增量批量（已完成）：

- `[server] event_batch_ms`（默认 25，0 = 关闭）：`text` / `reasoning` / `tool_args` 这些高频片段
  先攒进会话槽，按「窗口到期」或「攒满 4KB」成批交付；
- 交付时**合并相邻同类型片段**再调 `TurnSink`——只减少调用次数而不拼内容的话，
  UHP 侧照样一条一个 delta，等于白批（实测：20 片/无延迟，关闭批量 20 个 delta，开启后 1 个）；
- 控制性事件（`tool_call` / `tool_result` / `file`）与 `outcome` 不参与批量：交付前先把攒着的冲掉，
  保证输出顺序；
- 回合收口、提问上报、出错返回前都显式冲刷（终态是通过 invoke 返回值拿的，不一定有 outcome 事件）。

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
