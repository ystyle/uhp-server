#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
eval "$(cjvs env zsh)"
eval "$(cjvs stdx-env zsh)"
cjpm build -j 8
echo "==> uhp-server build ok: target/release/bin/uhp_server"
