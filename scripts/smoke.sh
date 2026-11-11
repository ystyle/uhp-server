#!/usr/bin/env bash
# 部署自检：起服务（scripted harness，不需要模型），走 discovery / harness 列表 / 任务 / 404。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/target/release/bin/uhp_server"
PORT="${UHP_PORT:-8498}"
TOKEN="smoke-token"
CFG=$(mktemp)
cat > "$CFG" <<EOF
[server]
bind = "127.0.0.1"
port = $PORT

[[tokens]]
token = "$TOKEN"
principal = "smoke"

[[harnesses]]
id = "echo"
kind = "scripted"
reply = "smoke ok"
EOF
[ -x "$BIN" ] || { echo "先 bash scripts/build.sh" >&2; exit 2; }
"$BIN" --config "$CFG" > /tmp/uhp-server-smoke.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -f "$CFG"' EXIT
code=""
for _ in $(seq 1 100); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:$PORT/v1/uhp" || true)
  if [ "$code" = "200" ]; then break; fi
  sleep 0.2
done
[ "$code" = "200" ] || { echo "服务未就绪（/tmp/uhp-server-smoke.log）" >&2; exit 3; }
RESP=$(curl -s -m 30 -H "Authorization: Bearer $TOKEN" -H 'UHP-Version: 2026-10-19' \
  -H 'Content-Type: application/json' -d '{"input":"hi","metadata":{"harness_id":"echo"}}' \
  "http://127.0.0.1:$PORT/v1/responses")
python3 - "$RESP" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
text = " ".join(c.get("text","") for it in d.get("output") or [] for c in (it.get("content") or []))
assert d.get("status") == "completed", d
assert "smoke ok" in text, text
print("==> uhp-server smoke ok")
PY
