#!/usr/bin/env bash
# 镜像冒烟：起容器 → 查发现文档 → 跑一个 scripted 任务 → 再验一个 isolate 任务（插件二进制在镜像里）
#                → 停容器看是否干净退出 → 清理。
#
# 用法：bash scripts/docker-smoke.sh [image] [port]
#   CI 里：docker build -t uhp-server:ci . && bash scripts/docker-smoke.sh uhp-server:ci 18488
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-uhp-server:ci}"
PORT="${2:-18488}"
TOKEN="smoke-token"
NAME="uhp-server-smoke"
# 工作目录放在仓库内（.smoke/，已 gitignore）：docker 是宿主进程，看不到沙箱/容器内的 /tmp。
WORK="$ROOT/.smoke/docker"
mkdir -p "$WORK"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

# 两个 harness：一个进程内、一个走插件进程（验证镜像里带上了 uhp_server.plugin）
cat > "$WORK/uhp-server.toml" <<EOF
[server]
bind = "0.0.0.0"
port = 8488

[[tokens]]
token = "$TOKEN"
principal = "smoke"

[[harnesses]]
id = "inline"
kind = "scripted"
reply = "inline ok"

[[harnesses]]
id = "isolated"
kind = "scripted"
reply = "plugin ok"
isolate = true
EOF

docker run -d --name "$NAME" -p "$PORT:8488" \
  -v "$WORK/uhp-server.toml:/app/uhp-server.toml:ro" "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:$PORT/v1/uhp" || true)
  [ "$code" = "200" ] && break
  sleep 0.5
done
if [ "${code:-}" != "200" ]; then
  echo "容器没起来（/v1/uhp 不是 200）" >&2
  docker logs "$NAME" >&2 || true
  exit 3
fi

ask() {
  curl -fsS -m 30 -H "Authorization: Bearer $TOKEN" -H 'UHP-Version: 2026-10-19' \
    -H 'Content-Type: application/json' \
    -d "{\"input\":\"hi\",\"metadata\":{\"harness_id\":\"$1\"}}" \
    "http://127.0.0.1:$PORT/v1/responses"
}

check() {
  python3 - "$1" "$2" <<'PY'
import json, sys
want, payload = sys.argv[1], sys.argv[2]
d = json.loads(payload)
assert d.get("status") == "completed", d
text = "".join(part.get("text", "") for item in d.get("output", [])
               for part in (item.get("content") or []))
assert want in text, (want, text)
print(f"  {want!r} ✓")
PY
}

echo "--- 进程内 harness"
check "inline ok" "$(ask inline)"
echo "--- 插件进程 harness（isolate = true）"
check "plugin ok" "$(ask isolated)"

# 停止必须快：镜像里用 tini 当 PID 1 转发 SIGTERM（否则 PID 1 会忽略信号，每次等满 10s 宽限）
start=$(date +%s%N)
docker stop "$NAME" >/dev/null
end=$(date +%s%N)
stop_ms=$(( (end - start) / 1000000 ))
echo "--- 停止耗时：${stop_ms}ms（退出码 $(docker inspect -f '{{.State.ExitCode}}' "$NAME")）"
if [ "$stop_ms" -gt 5000 ]; then
  echo "停止太慢（${stop_ms}ms）：SIGTERM 没被处理，检查镜像里是不是用 tini 当 PID 1" >&2
  exit 4
fi
echo "==> docker smoke ok（$IMAGE）"
