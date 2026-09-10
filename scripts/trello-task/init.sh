#!/usr/bin/env bash
# init.sh — определяет тег проекта и пишет .trello-project (env-формат).
#
# Тег по умолчанию выводится из git remote как owner/repo (в нижнем регистре):
# так однозначно видно, где живёт репозиторий — в организации или у
# пользователя. Явный --name перекрывает автовывод (например, короткий alias).
# Без remote или при непарсящемся URL скрипт ничего не пишет и просит
# спросить тег у пользователя явно.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/trello-task/init.sh [--name <tag>] [--force] [--remote <name>]
#
# Файл без секретов — можно коммитить.

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh" 2>/dev/null || {
  echo "trello-task: нет _common.sh рядом с init.sh" >&2; exit 1;
}

NAME_ARG=""
FORCE=0
REMOTE="origin"
OUT="$PROJECT_FILE"

usage() {
  echo "Usage: init.sh [--name <tag>] [--force] [--remote <name>]"
  echo "  Определяет тег проекта (по умолчанию owner/repo из git remote)"
  echo "  и пишет .trello-project в env-формате (NAME=..., без секретов)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)   NAME_ARG="${2:?--name требует значение}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    --remote) REMOTE="${2:?--remote требует имя remote}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "trello-task: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -f "$OUT" && "$FORCE" -eq 0 ]]; then
  echo "== уже инициализировано ($OUT) =="
  cat "$OUT"
  echo "Перезаписать: добавь --force (BOARD/LIST сохранятся, NAME обновится)."
  exit 0
fi

# Сохраняем дефолты доски/листа при --force, чтобы не потерять.
OLD_BOARD=""; OLD_LIST=""
if [[ -f "$OUT" ]]; then
  OLD_BOARD="$(grep -E '^BOARD=' "$OUT" | cut -d= -f2- || true)"
  OLD_LIST="$(grep -E '^LIST=' "$OUT" | cut -d= -f2- || true)"
fi

NAME="$NAME_ARG"
if [[ -z "$NAME" ]]; then
  URL="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
  [[ -n "$URL" ]] || {
    echo "trello-task: нет git remote '$REMOTE' — тег вывести не из чего." >&2
    echo "Спроси тег проекта у пользователя явно и перезапусти: init.sh --name <tag>" >&2
    exit 1
  }
  # git@host:owner/repo.git | https://host/owner/repo(.git) | ssh://git@host/owner/repo.git
  PATH_PART="$(printf '%s' "$URL" | sed -E -e 's#^[A-Za-z0-9+.-]+@[^:]+:##' -e 's#^[a-z]+://[^/]+/##' -e 's#\.git$##')"
  OWNER="${PATH_PART%%/*}"; REPO="${PATH_PART##*/}"
  if [[ -z "$OWNER" || -z "$REPO" || "$PATH_PART" != */* ]]; then
    echo "trello-task: не разобрал owner/repo из URL '$URL'." >&2
    echo "Спроси тег проекта у пользователя явно и перезапусти: init.sh --name <tag>" >&2
    exit 1
  fi
  NAME="$(printf '%s/%s' "$OWNER" "$REPO" | tr '[:upper:]' '[:lower:]')"
  echo "(i) Тег выведен из git remote '$REMOTE' ($URL)."
fi

# Базовая гигиена тега: непустой, одна строка, без '=' (env-формат).
[[ -n "$NAME" ]] || die "пустой тег — укажи явно: --name <tag>"
[[ "$NAME" != *$'\n'* && "$NAME" != *"="* ]] || die "тег не должен содержать перевод строки или '=': '$NAME'"

{
  echo "# .trello-project — тег проекта для Trello-задач (trello-task pipeline)."
  echo "# Сгенерировано scripts/trello-task/init.sh. Без секретов — можно коммитить."
  echo "# BOARD/LIST — дефолтные доска/лист (точные имена); запоминаются через create.sh --save-defaults."
  echo "NAME=$NAME"
  [[ -n "$OLD_BOARD" ]] && echo "BOARD=$OLD_BOARD"
  [[ -n "$OLD_LIST" ]] && echo "LIST=$OLD_LIST"
} > "$OUT"

echo "== записано ($OUT) =="
cat "$OUT"
