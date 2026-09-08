#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -d node_modules ]]; then
  echo "Installing dependencies (first run only)..." >&2
  npm install --no-fund --no-audit >&2
fi

exec node tunnel.js "$@"
