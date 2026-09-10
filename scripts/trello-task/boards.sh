#!/usr/bin/env bash
# boards.sh — список доступных досок (id + точное имя).
# Только чтение. Имена нужны для lists.sh / create.sh --board.
#
# Использование: bash .opencode/scripts/trello-task/boards.sh

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh"

usage() { echo "Usage: boards.sh"; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || { echo "trello-task: boards.sh без аргументов" >&2; usage >&2; exit 1; }

require_creds
echo "== мои открытые доски =="
trello_get "/members/me/boards" --data-urlencode "filter=open" --data-urlencode "fields=name" \
  | python3 -c 'import json, sys; [print(b["id"] + "\t" + str(b.get("name"))) for b in json.load(sys.stdin)]'
