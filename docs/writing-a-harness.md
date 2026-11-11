# 自己写一个 harness 适配器

uhp-server 的「接一个 agent」= 写一个**适配器**。有两条路：

| | 插件进程（推荐） | 进程内驱动 |
|---|---|---|
| 是什么 | 一个独立可执行文件，实现本文的小协议 | 实现 SDK 的 `HarnessDriver` 接口，编进 host |
| 要不要改 uhp-server | **不用**，只写配置 | 要改 `src/factory.cj`（加一个 kind） |
| 隔离性 | 独立进程，崩了只丢这一路 | 与 host 同生共死 |
| 适合 | 第三方 agent、重依赖、可能不稳的适配器 | 复用 SDK 里现成的驱动、轻量胶水 |

参照实现：[`src/examples/echo_plugin/main.cj`](../src/examples/echo_plugin/main.cj)（可运行、进 CI），
本文的配置片段由 [`src/echo_plugin_test.cj`](../src/echo_plugin_test.cj) 逐字验证。

## 1. 插件是什么

一个可执行文件，被 [cordis-cj](https://atomgit.com/ystyle/cordis-cj) 的 `PluginHost` 拉起，
通过 stdio JSON-RPC 和 host 通信。它对外只承诺一件事：**提供名为 `harness` 的服务**。

```text
uhp-server（host）                             你的插件进程
│  PluginHost.launchPlugin(entry)  ─────────▶  PluginRuntime.run(...)
│  ◀──────── initialize（插件 → host，握手）
│  invoke("harness", "info")       ─────────▶  返回 {base,label}：证明协议对上了
│  invoke("harness", "run", [sid,input]) ───▶  跑回合，边跑边写 stderr
│  ◀─ stderr 行：#UHP#{sid,seq,kind,text}      增量（text/tool_call/ask/file…）
│  ◀──────── invoke 返回终态字符串             completed / incomplete:… / failed:…
```

控制面（`invoke`）与数据面（stderr 行）是分开的：

- **控制面**是低频的方法调用，一问一答；
- **数据面**是高频的增量，约定成 stderr 上的一行一个 JSON。

为什么数据面不走 cordis 的事件总线：插件运行时的写通道不是线程无关的，在回合执行线程里
连续 `emit` 会把连接打断（实测首帧之后即断）。stderr 由宿主逐行转发，天然串行、也不占控制面通道。

## 2. 必须实现的方法

服务名固定 `harness`。`args` 是 JSON 数组，返回值是 JSON 值：

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `info` | — | `{base, label}` | 启动时握手检查；不应答会被当作「不是 harness 插件」并拒绝接入 |
| `run` | `sessionId`, `input` | 终态字符串 | **同步跑完整个回合**再返回；增量靠 stderr 上报 |
| `cancel` | `sessionId` | `true` | 置取消标志，`run` 里要轮询它 |
| `answer` | `sessionId`, `requestId`, `answer` | `true`/`false` | 送用户对某个 `ask` 的回答；id 对不上要返回 `false` |
| `closeSession` | `sessionId` | `true` | 回收会话级资源（agent 侧上下文等） |

`run` 的返回值（终态字符串）会映射成 UHP 的响应状态：

| 返回 | UHP 侧 |
|---|---|
| `completed` | 完成 |
| `cancelled` | 已取消 |
| `incomplete:input_required` | 待用户回答（配合 `ask` 用） |
| `incomplete:max_steps` / `incomplete:timeout` | 未完成，带原因 |
| `failed:<code>:<message>` | 失败，`code` 进 `error.code` |

## 3. 数据面：stderr 上的事件行

每条增量写成**一行**，前缀 `#UHP#`，紧跟 JSON：

```text
#UHP#{"ev":"harness","sid":"hsess_…","seq":7,"kind":"text","text":"片段"}
```

| 字段 | 说明 |
|---|---|
| `ev` | 固定 `"harness"`（留作以后扩展其它事件族） |
| `sid` | 会话 id（`run` 的第一个参数） |
| `seq` | **单调递增**的整数；宿主按它丢弃重复与迟到 |
| `kind` | 见下表 |
| `text` | 载荷；结构化内容自己编码成 JSON 字符串放这里 |

`kind` 取值：

| kind | text 内容 | 映射到 UHP |
|---|---|---|
| `text` | 正文片段 | `response.output_text.delta` |
| `reasoning` | 推理片段 | 推理事件 |
| `tool_call` | 工具名 + U+001F + 参数 JSON | 工具调用项 |
| `tool_result` | 调用 id + U+001F + 输出 | 工具结果项 |
| `tool_args` | 参数增量 | 参数增量事件 |
| `degrade` | 降级原因（如「该 agent 不支持 diff」） | 记日志 |
| `file` | `{"filename":"a.txt","data":"<base64>"}` | 会话产物 |
| `ask` | `{"requestId":"r1","askKind":"permission","prompt":"…","options":[{"id":"allow","label":"允许"}]}` | `input_request` |

U+001F 是单元分隔符：结构化字段用它拼，省一层 JSON，字段里不会出现这个字符。

## 4. 提问（两轮问答）

agent 要用户确认时，插件不能自己弹窗——得走 UHP 的 `input_request`：

```text
你：emit(kind="ask", text={requestId, askKind, prompt, options})，然后挂起轮询等 answer
宿主：把它变成 input_request，本轮以 incomplete(input_required) 收口
客户端：带上一轮 response id + input_response 再发一次 → 宿主调 answer(sessionId, requestId, 答案)
你：拿到答案继续跑，同一轮 run 里接着往下，最后返回 completed
```

三条硬约束：

1. **答案要按 `requestId` 校验**——迟到的旧答案不能喂给新提问，对不上返回 `false`；
2. 挂起期间要轮询 `cancel` 标志，否则取消不生效；
3. 超时没等到答案就返回 `incomplete:input_required`（别假装用户选了某一项）。

## 5. 打包与接入

### 5.1 编出可执行文件

在自己的 `cjpm.toml` 里声明（包名按你的工程改）：

```toml
[package.package-configuration."my_plugin"]
  output-type = "executable"
```

依赖只要两个：`ystyle::cordis_plugin`（起插件）+ `jsonvalue`（编 JSON）。

### 5.2 在配置里加上它

```toml
[[harnesses]]
id = "mine"
name = "我接的 agent"
kind = "echo-plugin"        # 自己起名：不是 acp/opencode/scripted 就按自写插件处理
isolate = true              # 必须在独立进程里跑，自写插件只支持这种模式
plugin_path = "/opt/uhp/plugins/echo_plugin"   # 缺省取 host 同目录的 uhp_server.plugin
plugin_args = ["--greeting", "你好"]           # 原样传给插件，宿主不解释
timeout_seconds = 600
```

> `plugin_args` 与 `args` 的区别：`args` 是给 ACP agent 的命令行参数（宿主会包成 `--arg` 传给内置插件），
> 自写插件要传自己的参数就用 `plugin_args`，宿主逐字转给你。

### 5.3 验证

```bash
./target/release/bin/uhp_server --config uhp-server.toml   # 启动日志里应有 harnesses: … mine
curl -s -H 'Authorization: Bearer dev-token' http://127.0.0.1:8488/v1/harnesses
curl -s -H 'Authorization: Bearer dev-token' -H 'UHP-Version: 2026-10-19' \
  -H 'Content-Type: application/json' -d '{"input":"hi","metadata":{"harness_id":"mine"}}' \
  http://127.0.0.1:8488/v1/responses
```

## 6. 自查清单

- [ ] `info` 能应答（不应答则宿主拒绝接入，日志是「插件未应答 info」）
- [ ] `run` 是**同步跑完整个回合**才返回：宿主按 invoke 的返回来收口
- [ ] 每条事件一行、`seq` 单调递增、`sid` 与会话一致
- [ ] 事件写在 **stderr**，日志不要往 stdout 打（stdout 是控制面协议）
- [ ] `cancel` 在 `run` 里被轮询到，取消后返回 `cancelled`
- [ ] `ask` 的答案按 `requestId` 校验，超时返回 `incomplete:input_required`
- [ ] 插件崩了不影响 host：宿主会把在跑的回合标失败，下一次 run 重新拉起进程

## 7. 调试

插件的 stderr（非 `#UHP#` 行）会被宿主加上 `[plugin:<id>]` 前缀原样打印，日志直接看得到。

| 现象 | 多半是什么 |
|---|---|
| 日志「插件未应答 info」 | 没实现 `info`，或返回值不是对象 |
| 回合直接 `failed`（`harness_error`） | `run` 抛了异常/返回了非字符串，或插件进程已退出 |
| 只有最后一段文本、没有增量 | 事件没写 stderr，或写成了 stdout |
| 答案送不进去 | `answer` 里 `requestId` 对不上（插件要存发起时的 id） |
| 想模拟崩溃做测试 | 用 `kill(getpid(), SIGKILL)`；**不要用 `std.env.exit`**——它走优雅关闭，在 handler 线程里会把进程卡住而不是退出 |

## 8. 另一条路：进程内驱动

如果适配器就该和 host 同生共死（或想直接复用 SDK 里的 `AcpDriver` / `OpencodeDriver`）：

1. 实现 `uhp.server.HarnessDriver`（`base` / `baseLabel` / `models` / `capabilities` / `run`）；
2. 需要会话/进程回收的话再实现 `HarnessLifecycle`（`close` / `closeSession`）；
3. 在 [`src/factory.cj`](../src/factory.cj) 的 `buildDriver` 里加一个 kind 分支；
4. 配置里 `isolate = false`（默认），其余照旧。

代价：多一个 kind 就要改一次 host 代码，且适配器崩了会把整个服务带走。
