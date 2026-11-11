#!/usr/bin/env bash
# TTL 驱逐自检：把 session_ttl_seconds 设成 1s，确认空闲会话会被回收（日志里出现回收行），
# 且服务在回收后仍能正常接新任务。
set -eo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/target/release/bin/uhp_server"
PORT="${UHP_PORT:-8497}"
TOKEN="ttl-token"
LOG=$(mktemp)
CFG=$(mktemp)
cat > "$CFG" <<EOF
[server]
bind = "127.0.0.1"
port = $PORT
session_ttl_seconds = 1

[[tokens]]
token = "$TOKEN"
principal = "smoke"

[[harnesses]]
id = "echo"
kind = "scripted"
reply = "ttl ok"
EOF
"$BIN" --config "$CFG" > "$LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -f "$CFG" "$LOG"' EXIT
code=""
for _ in $(seq 1 100); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:$PORT/v1/uhp" || true)
  if [ "$code" = "200" ]; then break; fi
  sleep 0.2
done
if [ "$code" != "200" ]; then echo "服务未就绪" >&2; cat "$LOG"; exit 3; fi

# 先跑一个任务制造会话，然后等 TTL 到期（1s TTL + 1s tick => 等 3s 足够）
curl -s -m 20 -H "Authorization: Bearer $TOKEN" -H 'UHP-Version: 2026-10-19' \
  -H 'Content-Type: application/json' -d '{"input":"hi","metadata":{"harness_id":"echo"}}' \
  "http://127.0.0.1:$PORT/v1/responses" > /dev/null
sleep 3

if ! grep -q '会话 TTL：回收' "$LOG"; then
  echo "没有看到会话回收日志（TTL 驱逐没生效）" >&2
  cat "$LOG"
  exit 4
fi

# 回收之后还能继续用
RESP=$(curl -s -m 20 -H "Authorization: Bearer $TOKEN" -H 'UHP-Version: 2026-10-19' \
  -H 'Content-Type: application/json' -d '{"input":"hi again","metadata":{"harness_id":"echo"}}' \
  "http://127.0.0.1:$PORT/v1/responses")
python3 - "$RESP" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d.get("status") == "completed", d
print("==> uhp-server session ttl smoke ok")
PY
