#!/usr/bin/env bash
# lists.sh — список открытых листов доски по её ТОЧНОМУ имени.
# Только чтение. Имена нужны для create.sh --list.
#
# Использование: bash .opencode/scripts/trello-task/lists.sh --board "<name>"

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh"

BOARD=""

usage() {
  echo "Usage: lists.sh --board \"<board name>\""
  echo "  Имя доски — точное (см. boards.sh)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) BOARD="${2:?--board требует имя доски}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "trello-task: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$BOARD" ]] || { echo "trello-task: укажи --board" >&2; usage >&2; exit 1; }

require_creds
BOARD_ID="$(find_board_id "$BOARD")" || exit 1
echo "== листы доски '$BOARD' =="
trello_get "/boards/${BOARD_ID}/lists" --data-urlencode "filter=open" --data-urlencode "fields=name" \
  | python3 -c 'import json, sys; [print(l["id"] + "\t" + str(l.get("name"))) for l in json.load(sys.stdin)]'
