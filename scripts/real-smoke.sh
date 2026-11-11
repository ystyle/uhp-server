#!/usr/bin/env bash
# 真实链路冒烟：uhp-server + 一个真 ACP agent（默认本机 opencode v2），跑一个真任务。
#
# 前置：本机有 opencode v2（OC_BIN 指向它）与可用模型。
# 用法：
#   bash scripts/real-smoke.sh                        # 默认 opencode acp
#   AGENT_CMD="dsh --profile acp" bash scripts/real-smoke.sh
#   AGENT_CMD="openma-pi-acp" bash scripts/real-smoke.sh
set -eo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
BIN="$ROOT/target/release/bin/uhp_server"
OCDIR="$ROOT/../.uhp-research/oc2"
OC_BIN="$OCDIR/pkg/node_modules/@opencode/cli-linux-x64/bin/opencode"
WS="$OCDIR/ws"
PORT="8499"
if [ -n "$UHP_PORT" ]; then PORT="$UHP_PORT"; fi
TOKEN="real-smoke-token"

if [ -z "$AGENT_CMD" ]; then
  if [ ! -x "$OC_BIN" ]; then echo "找不到 opencode v2（用 AGENT_CMD 指定别的 ACP agent）" >&2; exit 2; fi
  AGENT_CMD="$OC_BIN acp"
  # opencode 的隔离目录：不写用户 home
  export XDG_CONFIG_HOME="$OCDIR/config" XDG_CACHE_HOME="$OCDIR/cache"
  export XDG_DATA_HOME="$OCDIR/data" XDG_STATE_HOME="$OCDIR/state"
  export HOME="$OCDIR/home"
  mkdir -p "$HOME"
fi
if [ ! -d "$WS" ]; then echo "找不到工作目录：$WS" >&2; exit 2; fi
if [ ! -x "$BIN" ]; then echo "先 bash scripts/build.sh" >&2; exit 2; fi

# 把 "cmd arg1 arg2" 拆成 command + TOML 数组
AGENT_BIN=$(printf '%s' "$AGENT_CMD" | awk '{print $1}')
AGENT_ARGS=$(printf '%s' "$AGENT_CMD" | cut -s -d' ' -f2-)
ARGS_TOML="[]"
if [ -n "$AGENT_ARGS" ]; then
  JOINED=$(printf '"%s", ' $AGENT_ARGS)
  JOINED=$(printf '%s' "$JOINED" | sed 's/, $//')
  ARGS_TOML="[$JOINED]"
fi

CFG=$(mktemp)
cat > "$CFG" <<EOF
[server]
bind = "127.0.0.1"
port = $PORT

[[tokens]]
token = "$TOKEN"
principal = "smoke"

[[harnesses]]
id = "agent"
name = "real agent"
kind = "acp"
command = "$AGENT_BIN"
args = $ARGS_TOML
cwd = "$WS"
session_mode = "parallel"
timeout_seconds = 300
permission_timeout_seconds = 300
EOF

"$BIN" --config "$CFG" > /home/ystyle/Projects/Cangjie/.uhp-research/docker-test/server-real.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -f "$CFG"' EXIT

code=""
for _ in $(seq 1 100); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:$PORT/v1/uhp" || true)
  if [ "$code" = "200" ]; then break; fi
  sleep 0.2
done
if [ "$code" != "200" ]; then
  echo "服务未就绪" >&2
  tail -5 /home/ystyle/Projects/Cangjie/.uhp-research/docker-test/server-real.log
  exit 3
fi

echo "==> 跑真实任务（agent: $AGENT_CMD）"
RESP=$(mktemp)
START=$(date +%s%N)
curl -s -m 300 -H "Authorization: Bearer $TOKEN" -H 'UHP-Version: 2026-10-19' \
  -H 'Content-Type: application/json' \
  -d '{"input":"Reply with exactly: SERVER-OK","metadata":{"harness_id":"agent"}}' \
  "http://127.0.0.1:$PORT/v1/responses" > "$RESP"
END=$(date +%s%N)

python3 - "$RESP" "$(( (END-START)/1000000 ))" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
text = " ".join(c.get("text","") for it in d.get("output") or [] for c in (it.get("content") or []))
print("status:", d.get("status"), "elapsed_ms:", sys.argv[2])
print("text:", text[:200])
assert d.get("status") == "completed", "任务没有 completed"
assert "SERVER-OK" in text, "输出里没有 SERVER-OK"
print("==> uhp-server real smoke ok")
PY
