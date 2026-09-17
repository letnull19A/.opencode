#!/usr/bin/env bash
# label.sh — создаёт (или находит) метку проекта в Trello.
#
# Метка проекта — это Trello label с именем NAME из .trello-project
# (owner/repo). Используется для фильтрации карточек по проекту
# (см. audit.sh --tag). Скрипт идемпотентен: если метка уже есть — вернёт её id.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/task-manager/label.sh [--board "<name>"] [--name "<label>"] [--color <color>]
#
#   --board  Точное имя доски (см. boards.sh). Если не указан — берётся BOARD из .trello-project.
#   --name   Имя метки. Если не указано — берётся NAME из .trello-project.
#   --color  Цвет метки. По умолчанию lime_light (как у существующих проектных меток).
#            Допустимые: green yellow orange red purple blue sky lime pink black
#            и варианты *_dark / *_light (напр. lime_light, blue_dark).
#
# Требует: TRELLO_API_KEY, TRELLO_TOKEN в окружении, curl, python3.
# Примеры:
#   bash .opencode/scripts/task-manager/label.sh
#   bash .opencode/scripts/task-manager/label.sh --board "Aleksei — Work Hub" --color green
#   bash .opencode/scripts/task-manager/label.sh --board "Aleksei — Work Hub" --name "my-label" --color sky_light

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh"

BOARD=""; LABEL_NAME=""; COLOR="lime_light"

usage() {
  echo "Usage: label.sh [--board \"<board name>\"] [--name \"<label>\"] [--color <color>]"
  echo "  --board  Точное имя доски (по умолчанию BOARD из .trello-project)"
  echo "  --name   Имя метки (по умолчанию NAME из .trello-project)"
  echo "  --color  Цвет метки (по умолчанию lime_light)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) BOARD="${2:?--board требует имя доски}"; shift 2 ;;
    --name|--label) LABEL_NAME="${2:?--name требует имя метки}"; shift 2 ;;
    --color) COLOR="${2:?--color требует цвет}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "task-manager: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

# Валидация цвета (расширенный набор Trello)
case "$COLOR" in
  green|yellow|orange|red|purple|blue|sky|lime|pink|black|\
  green_dark|yellow_dark|orange_dark|red_dark|purple_dark|blue_dark|sky_dark|lime_dark|pink_dark|black_dark|\
  green_light|yellow_light|orange_light|red_light|purple_light|blue_light|sky_light|lime_light|pink_light|black_light|null) ;;
  *) die "неизвестный цвет метки '$COLOR' (можно: green yellow orange red purple blue sky lime pink black и *_dark/*_light, напр. lime_light)" ;;
esac

require_creds

# Подгружаем .trello-project если есть — для дефолтов BOARD/NAME
if [[ -f "$PROJECT_FILE" ]]; then
  load_project
fi

# Резолв дефолтов
if [[ -z "$BOARD" ]]; then
  BOARD="${BOARD:-}"
fi
if [[ -z "$LABEL_NAME" ]]; then
  LABEL_NAME="${NAME:-}"
fi

[[ -n "$BOARD" ]] || die "нет доски: передай --board или настрой дефолт (init.sh / create.sh --save-defaults)"
[[ -n "$LABEL_NAME" ]] || die "нет имени метки: передай --name или настрой .trello-project (init.sh)"

BOARD_ID="$(find_board_id "$BOARD")" || exit 1
LABEL_ID="$(ensure_label_id "$BOARD_ID" "$LABEL_NAME" "$COLOR")"

# Проверим что метка действительно на доске и выведем инфо
INFO="$(trello_get "/labels/${LABEL_ID}" --data-urlencode "fields=name,color")"
LABEL_COLOR="$(printf '%s' "$INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("color",""))')"
LABEL_NM="$(printf '%s' "$INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))')"

echo "== метка готова =="
echo "board: $BOARD ($BOARD_ID)"
echo "label: $LABEL_NM"
echo "color: $LABEL_COLOR"
echo "id:    $LABEL_ID"
