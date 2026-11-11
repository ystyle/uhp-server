# 发版

本仓是**产品**，不发中心仓。发布物两样：

| 产物 | 位置 |
|---|---|
| 二进制包（`uhp_server` + `uhp_server.plugin` + 配置样例 + README/LICENSE） | GitHub Release |
| 容器镜像 | `ghcr.io/ystyle/uhp-server`（tag = 版本号，另有 `latest`） |

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
3. 构建镜像 → 推 `ghcr.io/ystyle/uhp-server:<版本>` 与 `:latest`。

## 使用发布产物

```bash
docker pull ghcr.io/ystyle/uhp-server:0.1.1
docker run --rm -p 8488:8488 -v "$PWD/uhp-server.toml:/app/uhp-server.toml:ro" \
  ghcr.io/ystyle/uhp-server:0.1.1
```

二进制包解开即用（`uhp_server` 与 `uhp_server.plugin` 必须放同一目录：宿主默认按可执行文件所在目录找插件）。

## 兼容表

| uhp-server | uhp | uhp-acp / uhp-opencode | cordis-cj | 备注 |
|---|---|---|---|---|
| 0.1.x | path @ master | path @ master | path @ master | 开发期 |

> 现在依赖是 path 依赖（CI 里并行 checkout 兄弟仓）。等 `uhp` 与 cordis-cj 有可依赖的发布版本后，
> 把 `cjpm.toml` 切成中心仓精确版本，这张表就变成真正的版本约束。

## 镜像里的两个坑（已处理，别改回去）

1. **PID 1 忽略信号**：容器里 PID 1 对没有显式处理器的信号一律忽略，直接让 `uhp_server` 当 PID 1
   会导致 `docker stop` 每次等满 10s 宽限后被 SIGKILL（实测 10.2s / exit 137）。
   故镜像用 `docker/entrypoint.sh` 当 PID 1 转发 SIGTERM（实测 0.2s / exit 143）。
2. **构建上下文**：`target/` 几百 MB，不能进镜像上下文。`scripts/make-dist.sh` 只产出 `dist/`，
   `.dockerignore` 也只放行 `dist/ config/ docker/`。
