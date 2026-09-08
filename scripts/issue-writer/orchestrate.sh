#!/usr/bin/env bash
# Оркестратор пайплайна issue-writer. Сам не содержит LLM-логики —
# просто клеит шаги вместе в правильном порядке и в правильных местах
# останавливается для подтверждения человеком.
#
# Использование:
#   scripts/orchestrate.sh preview issue.json         # detect -> render, вывод в stdout
#   scripts/orchestrate.sh create  issue.json [labels] # detect -> render -> create (реальный issue!)
#
# issue.json — уже провалидированный JSON от subagent issue-writer
#              (после scripts/validate-issue-data.py)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:?usage: orchestrate.sh <preview|create> <issue.json> [labels_csv]}"
ISSUE_JSON="${2:?path to validated issue.json required}"
LABELS_CSV="${3:-}"

[[ -f "$ISSUE_JSON" ]] || { echo "orchestrate: файл не найден: $ISSUE_JSON" >&2; exit 1; }

PROVIDER="$("$DIR/detect-provider.sh")"
echo "→ provider: $PROVIDER" >&2

TITLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["title"])' "$ISSUE_JSON")"

TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"' EXIT
python3 "$DIR/render-issue.py" "$PROVIDER" --json "$ISSUE_JSON" --out "$TMP_BODY"

case "$MODE" in
  preview)
    echo "--- TITLE ---"
    echo "$TITLE"
    echo "--- BODY ($PROVIDER) ---"
    cat "$TMP_BODY"
    ;;
  create)
    "$DIR/create-issue.sh" "$PROVIDER" "$TITLE" "$TMP_BODY" "$LABELS_CSV"
    ;;
  *)
    echo "orchestrate: неизвестный режим '$MODE' (preview|create)" >&2
    exit 1
    ;;
esac
