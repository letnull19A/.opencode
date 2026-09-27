#!/usr/bin/env bash
# comments.sh — комментарии Trello-карточки: чтение для ИИ + добавление/правка/удаление.
#
# Зачем: веб-версия карточки требует JS, а агент сам curl к api.trello.com
# не делает (правила task-manager пайплайна) — весь Trello REST только здесь.
# Первичный сценарий — прочитать обсуждение задачи текстом:
#   comments.sh --id <shortLink|id> --show  → stdout только JSON.
# Селектор карточки — ровно один: --id | --url | --card [--from-board],
# как в checklist.sh / move.sh (resolve_card_id из _common.sh).
#
# Использование (из корня проекта):
#   comments.sh (--id <id> | --url <url> | --card "<name>" [--from-board "<b>"]) [--show | --list] [--limit <N>]
#   comments.sh (... ) --add "<текст>"
#   comments.sh (... ) --edit <actionId> --text "<новый текст>"
#   comments.sh (... ) --delete <actionId>
#
# --show/--list печатает в stdout только JSON (AI-first):
#   {card:{id,name,shortUrl}, count, comments:[{id,date,author:{fullName,username},text}]}.
# Остальные действия печатают короткий итог. --limit — макс. комментариев
# (по умолчанию 100). --show без других действий — действие по умолчанию.

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh"

ID=""; URL=""; CARD=""; FROM_BOARD=""
ACTION="show"; ARG=""; TEXT=""; LIMIT=100

usage() {
  echo "Usage: comments.sh (--id <card-id> | --url <card-url> | --card \"<exact name>\" [--from-board \"<b>\"]) [--show | --list | --add \"<text>\" | --edit <actionId> --text \"<text>\" | --delete <actionId>] [--limit <N>]"
  echo "  --show/--list возвращает JSON; --add/--edit/--delete меняют комментарии."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)         ID="${2:?--id требует id карточки (подходит и shortLink)}"; shift 2 ;;
    --url)        URL="${2:?--url требует URL карточки}"; shift 2 ;;
    --card)       CARD="${2:?--card требует точное имя}"; shift 2 ;;
    --from-board) FROM_BOARD="${2:?--from-board требует имя доски}"; shift 2 ;;
    --show|--list) ACTION="show"; shift ;;
    --add)        ACTION="add"; ARG="${2:?--add требует текст комментария}"; shift 2 ;;
    --edit)       ACTION="edit"; ARG="${2:?--edit требует id комментария (actionId)}"; shift 2 ;;
    --text)       TEXT="${2:?--text требует новый текст}"; shift 2 ;;
    --delete)     ACTION="delete"; ARG="${2:?--delete требует id комментария (actionId)}"; shift 2 ;;
    --limit)      LIMIT="${2:?--limit требует число}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "task-manager: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] && [[ "$LIMIT" -gt 0 ]] || { echo "task-manager: --limit: только положительное число" >&2; usage >&2; exit 1; }
if [[ "$ACTION" == "edit" && -z "$TEXT" ]]; then
  echo "task-manager: --edit требует --text \"<новый текст>\"" >&2; usage >&2; exit 1
fi

require_creds

SEL=()
[[ -n "$ID" ]] && SEL+=("--id" "$ID")
[[ -n "$URL" ]] && SEL+=("--url" "$URL")
[[ -n "$CARD" ]] && SEL+=("--card" "$CARD")
[[ -n "$FROM_BOARD" ]] && SEL+=("--from-board" "$FROM_BOARD")
[[ "${#SEL[@]}" -gt 0 ]] || { echo "task-manager: укажи карточку ровно одним способом: --id, --url или --card" >&2; usage >&2; exit 1; }
CARD_ID="$(resolve_card_id "${SEL[@]}")" || exit 1
CARD_JSON="$(trello_get "/cards/${CARD_ID}" --data-urlencode "fields=name,shortUrl")"
CARD_NAME="$(printf '%s' "$CARD_JSON" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("name", ""))')"
CARD_URL="$(printf '%s' "$CARD_JSON" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("shortUrl", ""))')"

case "$ACTION" in
  show)
    ACTIONS_JSON="$(trello_get "/cards/${CARD_ID}/actions" \
      --data-urlencode "filter=commentCard" \
      --data-urlencode "limit=${LIMIT}" \
      --data-urlencode "memberCreator_fields=fullName,username")"
    CARD_ID="$CARD_ID" CARD_NAME="$CARD_NAME" CARD_URL="$CARD_URL" ACTIONS_JSON="$ACTIONS_JSON" python3 -c '
import json, os
actions = json.loads(os.environ["ACTIONS_JSON"])
comments = []
for a in actions:
    mc = a.get("memberCreator") or {}
    data = a.get("data") or {}
    comments.append({
        "id": a.get("id"),
        "date": a.get("date"),
        "author": {"fullName": mc.get("fullName", ""), "username": mc.get("username", "")},
        "text": data.get("text", ""),
    })
print(json.dumps({
    "card": {"id": os.environ["CARD_ID"], "name": os.environ["CARD_NAME"], "shortUrl": os.environ["CARD_URL"]},
    "count": len(comments),
    "comments": comments,
}, ensure_ascii=False))
'
    ;;
  add)
    RESP="$(trello_post "/cards/${CARD_ID}/actions/comments" --data-urlencode "text=${ARG}")"
    NEW_ID="$(printf '%s' "$RESP" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))')"
    echo "== комментарий добавлен =="
    echo "card: $CARD_NAME"
    echo "url:  $CARD_URL"
    echo "id:   $NEW_ID"
    ;;
  edit)
    trello_put "/cards/${CARD_ID}/actions/${ARG}/comments" --data-urlencode "text=${TEXT}" >/dev/null
    echo "== комментарий обновлён =="
    echo "card: $CARD_NAME"
    echo "id:   $ARG"
    ;;
  delete)
    trello_delete "/cards/${CARD_ID}/actions/${ARG}/comments" >/dev/null
    echo "== комментарий удалён =="
    echo "card: $CARD_NAME"
    echo "id:   $ARG"
    ;;
esac
