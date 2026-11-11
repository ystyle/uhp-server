#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
eval "$(cjvs env zsh)"
eval "$(cjvs stdx-env zsh)"
cjpm build -j 8
cjpm test -j 4 --no-progress
echo "==> uhp-server tests ok"
