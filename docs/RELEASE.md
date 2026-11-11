# 发版

本仓是**产品**，不发中心仓。发布物两样：

| 产物 | 位置 |
|---|---|
| 二进制包（`uhp_server` + `uhp_server.plugin` + 配置样例 + README/LICENSE） | GitHub Release |
| 容器镜像 | `ghcr.io/ystyle/uhp-server`（tag 与 git tag 一致，如 `v0.1.0`，另有 `latest`） |

## 前置

- 依赖仓可访问：`ystyle/uhp`（GitHub）与 `cordis-cj`（仅 AtomGit）。CI 里由 `vars.UHP_REPO` /
  `vars.CORDIS_REPO_URL` 覆盖，默认已指向这两个地址。
- 仓库 Settings → Actions 允许写 packages（`GITHUB_TOKEN` 默认够用）。

## 步骤

```bash
# 1. 改版本号（唯一的版本来源：src/main.cj 的 UHP_SERVER_VERSION）
#    顺便更新 README 里的兼容表与镜像 tag
$EDITOR src/main.cj

# 2. 测试必须绿
bash scripts/test.sh

# 3. 提交并打 tag（AtomGit 是主仓，tag 两侧都要有）
git add -A && git commit -m "chore: 0.1.1"
git tag v0.1.1
git push origin master && git push origin v0.1.1
git push github master && git push github v0.1.1

# 4. 等工作流（Release）跑完：tag 会触发 artifacts + container 两个 job
gh run list -R ystyle/uhp-server --limit 3
```

工作流做三件事：

1. **版本一致性检查**：tag（`v0.1.1` → `0.1.1`）必须等于 `src/main.cj` 的 `UHP_SERVER_VERSION`，
   不一致直接失败（防止发出去的二进制自称另一个版本）；
2. 构建并打包 → GitHub Release 上传 tar.gz；
3. 构建镜像 → 推 `ghcr.io/ystyle/uhp-server:v<版本>`（与 git tag 同名）与 `:latest`。

## 使用发布产物

```bash
docker pull ghcr.io/ystyle/uhp-server:v0.1.1
docker run --rm -p 8488:8488 -v "$PWD/uhp-server.toml:/app/uhp-server.toml:ro" \
  ghcr.io/ystyle/uhp-server:v0.1.1
```

二进制包解开即用（`uhp_server` 与 `uhp_server.plugin` 必须放同一目录：宿主默认按可执行文件所在目录找插件）。

## 兼容表

| uhp-server | uhp | uhp-acp / uhp-opencode | cordis-cj | 备注 |
|---|---|---|---|---|
| 0.1.4+ | 0.1.1 | 0.1.1 | 0.3.1 | 全部中心仓依赖，CI 无需 checkout 兄弟仓 |
| 0.1.0–0.1.3 | path | path | path | 开发期 |

> 依赖已全部切到中心仓精确版本（uhp 0.1.1 / cordis 0.3.1）。升级依赖时改 `cjpm.toml` 的版本号并更新本表。

## 优雅退出（改之前先读）

主程序自己注册了信号处理器（`src/shutdown.cj`，用 `std.runtime.registerSignalHandler`）：

```text
SIGTERM / SIGINT → 处理器只无锁置位并返回 true（阻止默认终止）
                 → 后台线程收尾：停 HTTP（serve() 返回）→ Engine.close()（关 agent 子进程/插件进程）
                 → main 自然返回，进程 exit 0
```

**为什么必须有它**：容器里 PID 1 的内核语义是「没有处理器的信号一律忽略」。没有处理器时
`docker stop` 的 SIGTERM 被无视，每次都要等满 10s 宽限后被 SIGKILL（实测 10.2s / exit 137）。
有了处理器后实测停止耗时 **0.2s、退出码 0**（`scripts/docker-smoke.sh` 断言这两点）。
`std.env.atExit` 只在正常退出路径生效，信号路径指望不上——两者都要有。

## 构建上下文

`target/` 几百 MB，不能进镜像上下文。`scripts/make-dist.sh` 只产出 `dist/`，
`.dockerignore` 也只放行 `dist/ config/`。
