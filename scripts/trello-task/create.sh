#!/usr/bin/env bash
# create.sh — создаёт Trello-карточку с меткой проекта (NAME из .trello-project).
#
# Всё детерминированное — в коде: резолв доски/листа по ТОЧНЫМ именам,
# создание метки проекта при её отсутствии, создание карточки, возврат URL.
# Агент имена не выдумывает: точные имена брать из boards.sh / lists.sh
# или спрашивать у пользователя; дефолты BOARD/LIST — из .trello-project.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/trello-task/create.sh --title "<text>" [--board "<name>"] [--list "<name>"]
#       [--desc "<text>"] [--color <color>] [--save-defaults]
#
# Цвета меток Trello: green yellow orange red purple blue sky lime pink black.
# --save-defaults запоминает BOARD/LIST в .trello-project для следующих задач.

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh"

BOARD=""; LIST=""; TITLE=""; DESC=""; COLOR="green"; SAVE=0

usage() {
  echo "Usage: create.sh --title \"<text>\" [--board \"<name>\"] [--list \"<name>\"] [--desc \"<text>\"] [--color <color>] [--save-defaults]"
  echo "  --board/--list можно опустить, если BOARD/LIST уже есть в .trello-project."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) BOARD="${2:?--board требует имя доски}"; shift 2 ;;
    --list)  LIST="${2:?--list требует имя листа}"; shift 2 ;;
    --title) TITLE="${2:?--title требует текст}"; shift 2 ;;
    --desc)  DESC="${2:?--desc требует текст}"; shift 2 ;;
    --color) COLOR="${2:?--color требует цвет}"; shift 2 ;;
    --save-defaults) SAVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "trello-task: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$TITLE" ]] || { echo "trello-task: укажи --title" >&2; usage >&2; exit 1; }
case "$COLOR" in
  green|yellow|orange|red|purple|blue|sky|lime|pink|black) ;;
  *) die "неизвестный цвет метки '$COLOR' (можно: green yellow orange red purple blue sky lime pink black)" ;;
esac

load_project
require_creds

# Дефолты из .trello-project, если флаги не переданы.
[[ -n "$BOARD" ]] || BOARD="${BOARD:-}"
[[ -n "$LIST" ]] || LIST="${LIST:-}"
[[ -n "$BOARD" ]] || die "нет доски: передай --board или запомни дефолт (create.sh --board ... --list ... --save-defaults)"
[[ -n "$LIST" ]] || die "нет листа: передай --list или запомни дефолт (create.sh --board ... --list ... --save-defaults)"

BOARD_ID="$(find_board_id "$BOARD")" || exit 1
LIST_ID="$(find_list_id "$BOARD_ID" "$LIST")" || exit 1
LABEL_ID="$(ensure_label_id "$BOARD_ID" "$NAME" "$COLOR")"

RESP="$(trello_post "/cards" \
  --data-urlencode "idList=${LIST_ID}" \
  --data-urlencode "name=${TITLE}" \
  --data-urlencode "desc=${DESC}" \
  --data-urlencode "idLabels=${LABEL_ID}")"

URL="$(printf '%s' "$RESP" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d.get("shortUrl") or d.get("url"))')"
CARD_ID="$(printf '%s' "$RESP" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"

if [[ "$SAVE" -eq 1 ]]; then
  grep -v -E '^(BOARD|LIST)=' "$PROJECT_FILE" > "$PROJECT_FILE.tmp"
  {
    cat "$PROJECT_FILE.tmp"
    echo "BOARD=$BOARD"
    echo "LIST=$LIST"
  } > "$PROJECT_FILE"
  rm "$PROJECT_FILE.tmp"
  echo "(i) Дефолты записаны в $PROJECT_FILE: BOARD=$BOARD, LIST=$LIST."
fi

echo "== задача создана =="
echo "board: $BOARD"
echo "list:  $LIST"
echo "tag:   $NAME (метка доски)"
echo "title: $TITLE"
echo "url:   $URL"
echo "id:    $CARD_ID"
