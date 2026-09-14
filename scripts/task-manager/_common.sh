#!/usr/bin/env bash
# _common.sh — общие функции task-manager пайплайна. Не запускать напрямую:
# его source'ят остальные скрипты (init/boards/lists/create/move/audit).
# Требует: curl, python3. Секреты — только из окружения, никогда из файлов.

set -euo pipefail

TRELLO_API="https://api.trello.com/1"
PROJECT_FILE="${PROJECT_FILE:-.trello-project}"

die() { echo "task-manager: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "нужен '$1' (не найден в PATH)"
}
need_cmd curl
need_cmd python3

# Ключи — только env (те же, что у mcp.trello). В репозиторий не коммитить.
require_creds() {
  [[ -n "${TRELLO_API_KEY:-}" ]] || die "нет TRELLO_API_KEY — задай: export TRELLO_API_KEY=... (ключ: https://trello.com/app-key)"
  [[ -n "${TRELLO_TOKEN:-}" ]] || die "нет TRELLO_TOKEN — задай: export TRELLO_TOKEN=... (токен генерируется на той же странице)"
}

trello_get() { # trello_get <path> [--data-urlencode k=v ...]
  local path="$1"; shift
  curl -fsSL -G "${TRELLO_API}${path}" \
    --data-urlencode "key=${TRELLO_API_KEY}" \
    --data-urlencode "token=${TRELLO_TOKEN}" "$@" \
    || die "Trello API GET ${path} упал (проверь ключи и сеть)"
}

trello_post() { # trello_post <path> [--data-urlencode k=v ...]
  local path="$1"; shift
  curl -fsSL -X POST "${TRELLO_API}${path}" \
    --data-urlencode "key=${TRELLO_API_KEY}" \
    --data-urlencode "token=${TRELLO_TOKEN}" "$@" \
    || die "Trello API POST ${path} упал (проверь ключи, сеть и права токена read/write)"
}

trello_put() { # trello_put <path> [--data-urlencode k=v ...]
  local path="$1"; shift
  curl -fsSL -X PUT "${TRELLO_API}${path}" \
    --data-urlencode "key=${TRELLO_API_KEY}" \
    --data-urlencode "token=${TRELLO_TOKEN}" "$@" \
    || die "Trello API PUT ${path} упал (проверь ключи, сеть и права токена read/write)"
}

# Загружает .trello-project (env-формат) в переменные NAME/BOARD/LIST.
load_project() {
  [[ -f "$PROJECT_FILE" ]] || die "нет $PROJECT_FILE — сначала: bash .opencode/scripts/task-manager/init.sh"
  set -a
  # shellcheck disable=SC1090
  . "./$PROJECT_FILE"
  set +a
  [[ -n "${NAME:-}" ]] || die "$PROJECT_FILE без NAME — перезапусти: bash .opencode/scripts/task-manager/init.sh --force"
}

# Находит id доски по ТОЧНОМУ имени. Печатает id; exit 1 + подсказка иначе.
find_board_id() { # <board-name>
  local want="$1" json hits n
  json="$(trello_get "/members/me/boards" --data-urlencode "filter=open" --data-urlencode "fields=name")"
  hits="$(printf '%s' "$json" | python3 -c '
import json, sys
want = sys.argv[1]
for b in json.load(sys.stdin):
    if b.get("name") == want:
        print(b["id"])
' "$want")"
  n="$(printf '%s' "$hits" | grep -c . || true)"
  if [[ "$n" -eq 0 ]]; then
    echo "task-manager: доска '$want' не найдена. Доступные доски:" >&2
    printf '%s' "$json" | python3 -c 'import json, sys; [print(" -", b.get("name")) for b in json.load(sys.stdin)]' >&2
    return 1
  fi
  if [[ "$n" -gt 1 ]]; then
    die "досок с именем '$want' несколько ($n) — переименуй или уточни"
  fi
  printf '%s' "$hits"
}

# Находит id листа по ТОЧНОМУ имени на доске. Печатает id; exit 1 иначе.
find_list_id() { # <board-id> <list-name>
  local board_id="$1" want="$2" json hits n
  json="$(trello_get "/boards/${board_id}/lists" --data-urlencode "filter=open" --data-urlencode "fields=name")"
  hits="$(printf '%s' "$json" | python3 -c '
import json, sys
want = sys.argv[1]
for l in json.load(sys.stdin):
    if l.get("name") == want:
        print(l["id"])
' "$want")"
  n="$(printf '%s' "$hits" | grep -c . || true)"
  if [[ "$n" -eq 0 ]]; then
    echo "task-manager: лист '$want' не найден. Листы доски:" >&2
    printf '%s' "$json" | python3 -c 'import json, sys; [print(" -", l.get("name")) for l in json.load(sys.stdin)]' >&2
    return 1
  fi
  if [[ "$n" -gt 1 ]]; then
    die "листов с именем '$want' несколько ($n) — переименуй или уточни"
  fi
  printf '%s' "$hits"
}

# Возвращает id метки NAME на доске; создаёт её (цветом), если нет.
ensure_label_id() { # <board-id> <label-name> <color>
  local board_id="$1" want="$2" color="$3" json hit
  json="$(trello_get "/boards/${board_id}/labels" --data-urlencode "fields=name,color")"
  hit="$(printf '%s' "$json" | python3 -c '
import json, sys
want = sys.argv[1]
for l in json.load(sys.stdin):
    if l.get("name") == want:
        print(l["id"])
        break
' "$want")"
  if [[ -n "$hit" ]]; then
    printf '%s' "$hit"
    return 0
  fi
  trello_post "/boards/${board_id}/labels" \
    --data-urlencode "name=${want}" \
    --data-urlencode "color=${color}" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])'
}

# Резолвит карточку в её id. Селектор — ровно один:
# --id <id> | --url <card-url> | --card "<точное имя>" [--from-board "<доска>"].
# Печатает id карточки; exit 1 + подсказка иначе. Только чтение.
resolve_card_id() {
  local id="" url="" card="" from_board=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="${2:?--id требует id карточки}"; shift 2 ;;
      --url) url="${2:?--url требует URL карточки}"; shift 2 ;;
      --card) card="${2:?--card требует точное имя}"; shift 2 ;;
      --from-board) from_board="${2:?--from-board требует имя доски}"; shift 2 ;;
      *) die "resolve_card_id: неизвестный аргумент '$1'" ;;
    esac
  done

  local nsel=0
  [[ -n "$id" ]] && nsel=$((nsel+1))
  [[ -n "$url" ]] && nsel=$((nsel+1))
  [[ -n "$card" ]] && nsel=$((nsel+1))
  [[ "$nsel" -eq 1 ]] || die "укажи карточку ровно одним способом: --id, --url или --card"

  if [[ -n "$url" ]]; then
    id="$(printf '%s' "$url" | python3 -c '
import sys
parts = sys.stdin.read().strip().split("/")
try:
    print(parts[parts.index("c") + 1])
except (ValueError, IndexError):
    sys.exit("not a trello card url")
')" || die "не похоже на URL карточки Trello: '$url'"
  fi

  if [[ -n "$id" ]]; then
    trello_get "/cards/${id}" --data-urlencode "fields=id" \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])'
    return 0
  fi

  local search_boards matches nmatch scope
  if [[ -n "$from_board" ]]; then
    search_boards="$(find_board_id "$from_board")" || return 1
  else
    search_boards="$(trello_get "/members/me/boards" --data-urlencode "filter=open" --data-urlencode "fields=name" \
      | python3 -c 'import json, sys; [print(b["id"]) for b in json.load(sys.stdin)]')"
  fi
  matches=""
  local bid hits
  for bid in $search_boards; do
    hits="$(trello_get "/boards/${bid}/cards" --data-urlencode "fields=name" | python3 -c '
import json, sys
want = sys.argv[1]
for c in json.load(sys.stdin):
    if c.get("name") == want:
        print(c["id"] + "\t" + bid)
' "$card" "$bid")"
    [[ -n "$hits" ]] && matches="${matches}${hits}"$'\n'
  done
  nmatch="$(printf '%s' "$matches" | grep -c . || true)"
  if [[ "$nmatch" -eq 0 ]]; then
    scope="${from_board:-все открытые доски}"
    die "карточка '$card' не найдена ($scope) — проверь точное имя"
  fi
  if [[ "$nmatch" -gt 1 ]]; then
    echo "task-manager: карточек с именем '$card' несколько — уточни через --id или --url:" >&2
    printf '%s' "$matches" | while IFS=$'\t' read -r cid bid; do
      local bname
      bname="$(trello_get "/boards/${bid}" --data-urlencode "fields=name" | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])')"
      echo " - id=$cid (доска '$bname')" >&2
    done
    return 1
  fi
  printf '%s' "$matches" | cut -f1
}
