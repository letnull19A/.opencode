#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

BASE_URL=""
PAGES_FILE="./pages.example.json"
DELIVERY_METHOD="${DELIVERY_METHOD:-local}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2 ;;
    --pages) PAGES_FILE="$2"; shift 2 ;;
    --method) DELIVERY_METHOD="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$BASE_URL" ]]; then
  echo "Usage: run.sh --base-url https://your-app.com [--pages ./pages.json] [--method local|telegram|webhook|s3]"
  exit 1
fi

if [[ ! -d node_modules ]]; then
  echo "Installing dependencies (first run only)..."
  npm install
  npx playwright install --with-deps chromium
fi

echo "== 1/3 capture =="
CAPTURE_OUT=$(node capture.js --base-url "$BASE_URL" --pages "$PAGES_FILE")
echo "$CAPTURE_OUT"
RUN_DIR=$(echo "$CAPTURE_OUT" | grep '^RUN_DIR=' | cut -d'=' -f2-)

echo "== 2/3 report =="
node report.js --run-dir "$RUN_DIR"

echo "== 3/3 send ($DELIVERY_METHOD) =="
node send.js --run-dir "$RUN_DIR" --method "$DELIVERY_METHOD"

echo "Done: $RUN_DIR"
