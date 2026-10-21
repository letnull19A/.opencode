#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then echo "Usage: run.sh <start|status|url|restart|kill> [--port <n>] [--name <n>] [--ttl <s>] [--provider auto|ngrok|localtunnel] [--all]"; exit 0; fi
if [[ ! -d node_modules ]]; then
  echo "Installing dependencies (first run only)..." >&2
  npm install --no-fund --no-audit >&2
fi

exec node tunnel.js "$@"
