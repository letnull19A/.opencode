#!/usr/bin/env bash
# move.sh — перемещает Trello-карточку в другой лист (той же или другой доски).
#
# Всё детерминированное — в коде: поиск карточки (id/URL/точное имя),
# резолв целевых доски/листа по ТОЧНЫМ именам, PUT idList. Агент id
# и имена не выдумывает: карточку находит скрипт, точные имена досок/листов
# — из boards.sh / lists.sh или из слов пользователя.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/trello-task/move.sh (--id <id> | --url <url> | --card "<name>" [--from-board "<b>"]) --list "<target>" [--to-board "<b>"] [--pos top|bottom|N] [--dry-run]
#
# --to-board без флага = текущая доска карточки (перемещение внутри доски).
# --pos по умолчанию bottom. --dry-run резолвит всё и показывает план без PUT.

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh"

ID=""; URL=""; CARD=""; FROM_BOARD=""; LIST=""; TO_BOARD=""; POS="bottom"; DRY=0

usage() {
  echo "Usage: move.sh (--id <card-id> | --url <card-url> | --card \"<exact name>\" [--from-board \"<b>\"]) --list \"<target list>\" [--to-board \"<b>\"] [--pos top|bottom|N] [--dry-run]"
  echo "  Карточка — ровно одним способом; цель --list обязателен (точное имя)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)         ID="${2:?--id требует id карточки}"; shift 2 ;;
    --url)        URL="${2:?--url требует URL карточки}"; shift 2 ;;
    --card)       CARD="${2:?--card требует точное имя}"; shift 2 ;;
    --from-board) FROM_BOARD="${2:?--from-board требует имя доски}"; shift 2 ;;
    --list)       LIST="${2:?--list требует имя целевого листа}"; shift 2 ;;
    --to-board)   TO_BOARD="${2:?--to-board требует имя доски}"; shift 2 ;;
    --pos)        POS="${2:?--pos требует top|bottom|N}"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "trello-task: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

# Карточка — ровно один селектор.
NSEL=0
[[ -n "$ID" ]] && NSEL=$((NSEL+1))
[[ -n "$URL" ]] && NSEL=$((NSEL+1))
[[ -n "$CARD" ]] && NSEL=$((NSEL+1))
[[ "$NSEL" -eq 1 ]] || { echo "trello-task: укажи карточку ровно одним способом: --id, --url или --card" >&2; usage >&2; exit 1; }
[[ -n "$LIST" ]] || { echo "trello-task: укажи целевой --list" >&2; usage >&2; exit 1; }
[[ "$POS" == "top" || "$POS" == "bottom" || "$POS" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || die "--pos: только top|bottom|число, получено '$POS'"

require_creds

# 1. Резолв исходной карточки → CARD_ID + текущие доска/лист.
if [[ -n "$URL" ]]; then
  ID="$(printf '%s' "$URL" | python3 -c '
import sys
parts = sys.stdin.read().strip().split("/")
try:
    print(parts[parts.index("c") + 1])
except (ValueError, IndexError):
    sys.exit("not a trello card url")
')" || die "не похоже на URL карточки Trello: '$URL'"
fi

if [[ -n "$ID" ]]; then
  INFO="$(trello_get "/cards/${ID}" --data-urlencode "fields=name,idBoard,idList,shortUrl")"
  CARD_ID="$(printf '%s' "$INFO" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
  CARD_NAME="$(printf '%s' "$INFO" | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])')"
  CUR_BOARD_ID="$(printf '%s' "$INFO" | python3 -c 'import json, sys; print(json.load(sys.stdin)["idBoard"])')"
  CUR_LIST_ID="$(printf '%s' "$INFO" | python3 -c 'import json, sys; print(json.load(sys.stdin)["idList"])')"
  CARD_URL="$(printf '%s' "$INFO" | python3 -c 'import json, sys; print(json.load(sys.stdin)["shortUrl"])')"
else
  # Поиск по точному имени: в --from-board или по всем открытым доскам.
  if [[ -n "$FROM_BOARD" ]]; then
    SEARCH_BOARDS="$(find_board_id "$FROM_BOARD")" || exit 1
  else
    SEARCH_BOARDS="$(trello_get "/members/me/boards" --data-urlencode "filter=open" --data-urlencode "fields=name" \
      | python3 -c 'import json, sys; [print(b["id"]) for b in json.load(sys.stdin)]')"
  fi
  MATCHES=""
  for BID in $SEARCH_BOARDS; do
    HITS="$(trello_get "/boards/${BID}/cards" --data-urlencode "fields=name,idList" | python3 -c '
import json, sys
want = sys.argv[1]
bid = sys.argv[2]
for c in json.load(sys.stdin):
    if c.get("name") == want:
        print(c["id"] + "\t" + c["idList"] + "\t" + bid)
' "$CARD" "$BID")"
    [[ -n "$HITS" ]] && MATCHES="${MATCHES}${HITS}"$'\n'
  done
  NMATCH="$(printf '%s' "$MATCHES" | grep -c . || true)"
  if [[ "$NMATCH" -eq 0 ]]; then
    SCOPE="${FROM_BOARD:-все открытые доски}"
    die "карточка '$CARD' не найдена ($SCOPE) — проверь точное имя"
  fi
  if [[ "$NMATCH" -gt 1 ]]; then
    echo "trello-task: карточек с именем '$CARD' несколько — уточни через --id или --url:" >&2
    printf '%s' "$MATCHES" | while IFS=$'\t' read -r cid _ bid; do
      BNAME="$(trello_get "/boards/${bid}" --data-urlencode "fields=name" | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])')"
      echo " - id=$cid (доска '$BNAME')" >&2
    done
    exit 1
  fi
  CARD_ID="$(printf '%s' "$MATCHES" | cut -f1)"
  CUR_LIST_ID="$(printf '%s' "$MATCHES" | cut -f2)"
  CUR_BOARD_ID="$(printf '%s' "$MATCHES" | cut -f3)"
  CARD_NAME="$CARD"
  CARD_URL="$(trello_get "/cards/${CARD_ID}" --data-urlencode "fields=shortUrl" | python3 -c 'import json, sys; print(json.load(sys.stdin)["shortUrl"])')"
fi

CUR_BOARD_NAME="$(trello_get "/boards/${CUR_BOARD_ID}" --data-urlencode "fields=name" | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])')"
CUR_LIST_NAME="$(trello_get "/lists/${CUR_LIST_ID}" --data-urlencode "fields=name" | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])')"

# 2. Резолв цели (доска по умолчанию — текущая).
[[ -n "$TO_BOARD" ]] || TO_BOARD="$CUR_BOARD_NAME"
TO_BOARD_ID="$(find_board_id "$TO_BOARD")" || exit 1
TO_LIST_ID="$(find_list_id "$TO_BOARD_ID" "$LIST")" || exit 1

if [[ "$TO_LIST_ID" == "$CUR_LIST_ID" ]]; then
  echo "Нечего перемещать: карточка '$CARD_NAME' уже в листе '$CUR_LIST_NAME'."
  echo "url: $CARD_URL"
  exit 0
fi

if [[ "$DRY" -eq 1 ]]; then
  echo "== dry-run: ничего не меняю =="
  echo "card:  $CARD_NAME"
  echo "from:  $CUR_BOARD_NAME / $CUR_LIST_NAME"
  echo "to:    $TO_BOARD / $LIST (pos $POS)"
  echo "url:   $CARD_URL"
  exit 0
fi

# 3. Перемещение. Только PUT idList (+pos) — других мутаций скрипт не делает.
trello_put "/cards/${CARD_ID}" \
  --data-urlencode "idList=${TO_LIST_ID}" \
  --data-urlencode "pos=${POS}" >/dev/null

echo "== задача перемещена =="
echo "card:  $CARD_NAME"
echo "from:  $CUR_BOARD_NAME / $CUR_LIST_NAME"
echo "to:    $TO_BOARD / $LIST (pos $POS)"
echo "url:   $CARD_URL"
