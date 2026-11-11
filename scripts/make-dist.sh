#!/usr/bin/env bash
# 产出镜像/发行包要用的「最小产物目录」dist/：
#   dist/uhp_server            主程序
#   dist/uhp_server.plugin     harness 插件进程（isolate = true 的 harness 用）
#
# 为什么单独一步：镜像构建上下文只带 dist/（见 .dockerignore），
# 否则会把整个 target/ 塞给 docker daemon（几百 MB）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# 本机用 cjvs 切工具链；CI 里工具链已由 action 装好，没有 cjvs 就直接用 cjpm
if command -v cjvs >/dev/null 2>&1; then
    eval "$(cjvs env zsh)"
    eval "$(cjvs stdx-env zsh)"
fi
cjpm build -j 8
rm -rf dist
mkdir -p dist
cp target/release/bin/uhp_server dist/uhp_server
cp target/release/bin/uhp_server.plugin dist/uhp_server.plugin
chmod 0755 dist/uhp_server dist/uhp_server.plugin
echo "==> dist ok:"
ls -lh dist/
