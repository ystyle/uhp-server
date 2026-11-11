# uhp-server 约定

> 工作区通用约定见 [../uhp/AGENTS.md](../uhp/AGENTS.md) 与 [../AGENTS.md](../AGENTS.md)。
> 本仓是**产品**（可执行），不是库。

## 1. 定位

- 本仓 = UHP 服务端的成品：装配 `Engine` + `UhpHttpServer` + 多个 harness 适配器。
- **协议逻辑不在这里**：协议面、状态机、错误模型来自依赖的 `uhp`；适配器来自 `uhp-acp` / `uhp-opencode`。
  这里只做「配置 → 装配 → 进程/端口/日志/部署」这些产品层的事。
- 与客户端分工：客户端（如 atelier-starline）只跑 UHP client；本仓只跑 server。

## 2. 布局

```text
uhp-server/
├── src/                  host 实现（唯一包）
│   ├── main.cj           CLI、启动、监听
│   ├── config.cj         TOML 配置模型与加载
│   ├── factory.cj        配置条目 → ConfiguredHarness（按 kind 选驱动）
│   ├── config_test.cj    配置/工厂单测
│   ├── server_e2e_test.cj 真起 server + SDK client 的端到端
│   ├── plugin/           harness 插件进程（P1：把内置适配器放进独立进程）
│   └── examples/         示例插件（自己写适配器的参照实现）
├── config/               配置样例
├── docs/                 设计（design.md）与「怎么写适配器」（writing-a-harness.md）
├── scripts/              build / test / smoke
└── Dockerfile  docker-compose.yml
```

## 3. 命令

```bash
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
bash scripts/build.sh     # cjpm build -j 8
bash scripts/test.sh      # cjpm test -j 4（含 e2e，不需要模型）
bash scripts/smoke.sh     # 起服务 + curl 自检（scripted harness）
```

## 4. 边界与纪律

- **依赖方向**：本仓 → `uhp` / 适配器库，单向。不要把协议实现抄进来，也不要让 `uhp` 反过来依赖本仓。
- **配置错误 fail fast**：未知 kind、缺必填字段、重复 harness id 一律启动失败（`ServerConfigError`），
  不要「先跑起来再说」。
- **测试不许依赖模型/凭据**：默认用 `kind=scripted` 的 harness 做端到端；真实链路验证放 `scripts/` 的 smoke，不进出口。
- **driver 生命周期**：P0 适配器在 host 进程内，进程退出即回收；接入 `close()/closeSession()` 的清理路径要在装配层做对。

## 5. 发版

- 本仓是**产品**，不发中心仓；发布物 = git tag + 二进制包 + Docker 镜像。
- 版本独立于 `uhp`：README/`docs/design.md` 里维护「server ↔ uhp ↔ 适配器」兼容表。
- 切发布依赖时把 `cjpm.toml` 的 path 依赖换成中心仓精确版本（见 docs/design.md「发布」）。
