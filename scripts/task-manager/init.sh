#!/usr/bin/env bash
# init.sh — определяет тег проекта и пишет .devbox-project (env-формат, ранее .trello-project).
#
# Тег по умолчанию выводится из git remote как owner/repo (в нижнем регистре):
# так однозначно видно, где живёт репозиторий — в организации или у
# пользователя. Явный --name перекрывает автовывод (например, короткий alias).
# Без remote или при непарсящемся URL скрипт ничего не пишет и просит
# спросить тег у пользователя явно.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/task-manager/init.sh [--name <tag>] [--force] [--remote <name>]
#
# Файл без секретов — можно коммитить.

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh" 2>/dev/null || {
  echo "task-manager: нет _common.sh рядом с init.sh" >&2; exit 1;
}

NAME_ARG=""
FORCE=0
REMOTE="origin"
OUT="$PROJECT_FILE"
# onboarding profile (опц., пишутся как PROFILE_* в .devbox-project)
PROFILE_MONOREPO=""
PROFILE_MICROSERVICES=""
PROFILE_FRONTEND=""
PROFILE_BACKEND=""
PROFILE_DATABASE=""
PROFILE_TYPE=""
PROFILE_COMMIT_MODE=""
PROFILE_APPS_DIR=""

usage() {
  echo "Usage: init.sh [--name <tag>] [--force] [--remote <name>] [--monorepo <yes|no>] [--microservices <yes|no>] [--frontend <stack|none>] [--backend <stack|none>] [--database <type|none>] [--project-type <draft|mvp>] [--commit-mode <all|batch>] [--apps-dir <dir>]"
  echo "  Определяет тег проекта (по умолчанию owner/repo из git remote)"
  echo "  и пишет .devbox-project в env-формате (NAME=..., без секретов)."
  echo "  Onboarding-флаги PROFILE_* опциональны; их задаёт @init/@onboarding через question tool."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)   NAME_ARG="${2:?--name требует значение}"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    --remote) REMOTE="${2:?--remote требует имя remote}"; shift 2 ;;
    --monorepo) PROFILE_MONOREPO="${2:?--monorepo yes|no}"; shift 2 ;;
    --microservices) PROFILE_MICROSERVICES="${2:?--microservices yes|no}"; shift 2 ;;
    --frontend) PROFILE_FRONTEND="${2:?--frontend stack|none}"; shift 2 ;;
    --backend) PROFILE_BACKEND="${2:?--backend stack|none}"; shift 2 ;;
    --database) PROFILE_DATABASE="${2:?--database type|none}"; shift 2 ;;
    --project-type) PROFILE_TYPE="${2:?--project-type draft|mvp}"; shift 2 ;;
    --commit-mode) PROFILE_COMMIT_MODE="${2:?--commit-mode all|batch}"; shift 2 ;;
    --apps-dir) PROFILE_APPS_DIR="${2:?--apps-dir dir}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "task-manager: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -f "$OUT" && "$FORCE" -eq 0 ]]; then
  echo "== уже инициализировано ($OUT) =="
  cat "$OUT"
  echo "Перезаписать: добавь --force (BOARD/LIST сохранятся, NAME обновится)."
  exit 0
fi

# Сохраняем дефолты доски/листа и PROFILE_* при --force, чтобы не потерять.
OLD_BOARD=""; OLD_LIST=""
OLD_PROFILE=""
if [[ -f "$OUT" ]]; then
  OLD_BOARD="$(grep -E '^BOARD=' "$OUT" | cut -d= -f2- || true)"
  OLD_LIST="$(grep -E '^LIST=' "$OUT" | cut -d= -f2- || true)"
  OLD_PROFILE="$(grep -E '^PROFILE_' "$OUT" || true)"
fi

NAME="$NAME_ARG"
if [[ -z "$NAME" ]]; then
  URL="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
  [[ -n "$URL" ]] || {
    echo "task-manager: нет git remote '$REMOTE' — тег вывести не из чего." >&2
    echo "Спроси тег проекта у пользователя явно и перезапусти: init.sh --name <tag>" >&2
    exit 1
  }
  # git@host:owner/repo.git | https://host/owner/repo(.git) | ssh://git@host/owner/repo.git
  PATH_PART="$(printf '%s' "$URL" | sed -E -e 's#^[A-Za-z0-9+.-]+@[^:]+:##' -e 's#^[a-z]+://[^/]+/##' -e 's#\.git$##')"
  OWNER="${PATH_PART%%/*}"; REPO="${PATH_PART##*/}"
  if [[ -z "$OWNER" || -z "$REPO" || "$PATH_PART" != */* ]]; then
    echo "task-manager: не разобрал owner/repo из URL '$URL'." >&2
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
  echo "# .devbox-project — тег проекта для Trello-задач (task-manager pipeline, ранее .trello-project)."
  echo "# Сгенерировано scripts/task-manager/init.sh. Без секретов — можно коммитить."
  echo "# BOARD/LIST — дефолтные доска/лист (точные имена); запоминаются через create.sh --save-defaults."
  echo "NAME=$NAME"
  if [[ -n "$OLD_BOARD" ]]; then
    _b="$(printf '%s' "$OLD_BOARD" | sed -e 's/^"//' -e 's/"$//')"
    printf 'BOARD="%s"\n' "$(printf '%s' "$_b" | sed 's/"/\\"/g')"
  fi
  if [[ -n "$OLD_LIST" ]]; then
    _l="$(printf '%s' "$OLD_LIST" | sed -e 's/^"//' -e 's/"$//')"
    printf 'LIST="%s"\n' "$(printf '%s' "$_l" | sed 's/"/\\"/g')"
  fi
  # onboarding profile — сохраняем старые, перезаписываем только переданными флагами
  if [[ -n "$OLD_PROFILE" && -z "$PROFILE_MONOREPO$PROFILE_MICROSERVICES$PROFILE_FRONTEND$PROFILE_BACKEND$PROFILE_DATABASE$PROFILE_TYPE$PROFILE_COMMIT_MODE$PROFILE_APPS_DIR" ]]; then
    # без новых флагов — сохраняем старый профиль как есть (при --force без профиля)
    printf '%s\n' "$OLD_PROFILE"
  else
    # есть новые флаги — мерджим: сначала старые, затем перезаписываем переданными
    # собираем ассоциативно через временный файл
    if [[ -n "$OLD_PROFILE" ]]; then
      # выводим старые кроме тех, что перезаписываются
      printf '%s\n' "$OLD_PROFILE" | while IFS= read -r line; do
        key="${line%%=*}"
        case "$key" in
          PROFILE_MONOREPO) [[ -n "$PROFILE_MONOREPO" ]] || printf '%s\n' "$line" ;;
          PROFILE_MICROSERVICES) [[ -n "$PROFILE_MICROSERVICES" ]] || printf '%s\n' "$line" ;;
          PROFILE_FRONTEND) [[ -n "$PROFILE_FRONTEND" ]] || printf '%s\n' "$line" ;;
          PROFILE_BACKEND) [[ -n "$PROFILE_BACKEND" ]] || printf '%s\n' "$line" ;;
          PROFILE_DATABASE) [[ -n "$PROFILE_DATABASE" ]] || printf '%s\n' "$line" ;;
          PROFILE_TYPE) [[ -n "$PROFILE_TYPE" ]] || printf '%s\n' "$line" ;;
          PROFILE_COMMIT_MODE) [[ -n "$PROFILE_COMMIT_MODE" ]] || printf '%s\n' "$line" ;;
          PROFILE_APPS_DIR) [[ -n "$PROFILE_APPS_DIR" ]] || printf '%s\n' "$line" ;;
          *) printf '%s\n' "$line" ;;
        esac
      done
    fi
    [[ -z "$PROFILE_MONOREPO" ]] || echo "PROFILE_MONOREPO=$PROFILE_MONOREPO"
    [[ -z "$PROFILE_MICROSERVICES" ]] || echo "PROFILE_MICROSERVICES=$PROFILE_MICROSERVICES"
    [[ -z "$PROFILE_FRONTEND" ]] || echo "PROFILE_FRONTEND=$PROFILE_FRONTEND"
    [[ -z "$PROFILE_BACKEND" ]] || echo "PROFILE_BACKEND=$PROFILE_BACKEND"
    [[ -z "$PROFILE_DATABASE" ]] || echo "PROFILE_DATABASE=$PROFILE_DATABASE"
    [[ -z "$PROFILE_TYPE" ]] || echo "PROFILE_TYPE=$PROFILE_TYPE"
    [[ -z "$PROFILE_COMMIT_MODE" ]] || echo "PROFILE_COMMIT_MODE=$PROFILE_COMMIT_MODE"
    [[ -z "$PROFILE_APPS_DIR" ]] || echo "PROFILE_APPS_DIR=$PROFILE_APPS_DIR"
  fi
} > "$OUT"

echo "== записано ($OUT) =="
cat "$OUT"
