#!/usr/bin/env bash
# audit.sh — read-only аудит Trello-доски с выводом СТРОГО JSON для ИИ-агента.
#
# Первичный потребитель — агент task-audit (затем task-manager), не человек:
# stdout — только чистый JSON без markdown/заголовков, чтобы менеджер парсил
# totals/lists/overdue без гаданий и не выдумывал имена/даты.
# Никаких мутаций: только GET. Ошибки — JSON-объект с полем "error" в stdout.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/task-manager/audit.sh --board "<name>" [--tag "<tag>" | --all] [--limit <N>]
#
#   --board обязателен, если BOARD нет в .trello-project (точное имя, см. boards.sh).
#   По умолчанию фильтр по NAME из .trello-project; --all — без фильтра;
#   --tag перекрывает NAME. --limit — макс. карточек на лист (по умолчанию 50).

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh"

BOARD=""; TAG_OVERRIDE=""; SHOW_ALL=0; LIMIT=50

usage() {
  echo "Usage: audit.sh --board \"<board name>\" [--tag \"<tag>\" | --all] [--limit <N>]"
  echo "  Печатает в stdout только JSON (см. schema/audit.schema.json)."
}

err_json() { # <code> <hint>
  python3 -c 'import json,sys; print(json.dumps({"error": sys.argv[1], "hint": sys.argv[2]}, ensure_ascii=False))' "$1" "$2"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) BOARD="${2:?--board требует имя доски}"; shift 2 ;;
    --tag) TAG_OVERRIDE="${2:?--tag требует значение}"; shift 2 ;;
    --all) SHOW_ALL=1; shift ;;
    --limit) LIMIT="${2:?--limit требует число}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err_json "bad_args" "неизвестный аргумент '$1'"; usage >&2; exit 1 ;;
  esac
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] && [[ "$LIMIT" -gt 0 ]] || { err_json "bad_limit" "--limit: только положительное число"; exit 1; }

# Проектный файл нужен для дефолтов NAME/BOARD (без секретов).
if [[ ! -f "$PROJECT_FILE" ]]; then
  err_json "no_project" "нет $PROJECT_FILE — сначала: bash .opencode/scripts/task-manager/init.sh"
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "./$PROJECT_FILE"
set +a

[[ -n "$BOARD" ]] || BOARD="${BOARD:-}"
if [[ -z "$BOARD" ]]; then
  err_json "no_board" "нет доски: передай --board \"<точное имя>\" (см. boards.sh) или запомни дефолт"
  exit 1
fi

FILTER_TAG=""
FILTER_MODE="tag"
if [[ "$SHOW_ALL" -eq 1 ]]; then
  FILTER_MODE="all"
elif [[ -n "$TAG_OVERRIDE" ]]; then
  FILTER_TAG="$TAG_OVERRIDE"
else
  FILTER_TAG="${NAME:-}"
fi
if [[ "$FILTER_MODE" == "tag" && -z "$FILTER_TAG" ]]; then
  err_json "no_tag" "$PROJECT_FILE без NAME — перезапусти init.sh --force или передай --tag/--all"
  exit 1
fi

require_creds

BOARD_ID="$(find_board_id "$BOARD")" || {
  AVAILABLE="$(trello_get "/members/me/boards" --data-urlencode "filter=open" --data-urlencode "fields=name" | python3 -c 'import json,sys; print(json.dumps([b.get("name") for b in json.load(sys.stdin)], ensure_ascii=False))')"
  python3 -c 'import json,sys; print(json.dumps({"error": "board_not_found", "board": sys.argv[1], "available_boards": json.loads(sys.argv[2])}, ensure_ascii=False))' "$BOARD" "$AVAILABLE"
  exit 1
}

LISTS_JSON="$(trello_get "/boards/${BOARD_ID}/lists" --data-urlencode "filter=open" --data-urlencode "fields=name")"
CARDS_JSON="$(trello_get "/boards/${BOARD_ID}/cards" --data-urlencode "fields=name,idList,due,dueComplete,labels,shortUrl")"

export FILTER_TAG FILTER_MODE BOARD BOARD_ID LIMIT
LISTS_JSON="$LISTS_JSON" CARDS_JSON="$CARDS_JSON" python3 -c '
import json, os, sys
from datetime import datetime, timezone

board = os.environ["BOARD"]
board_id = os.environ["BOARD_ID"]
filter_tag = os.environ.get("FILTER_TAG", "")
filter_mode = os.environ.get("FILTER_MODE", "tag")
limit = int(os.environ.get("LIMIT", "50"))

lists = json.loads(os.environ["LISTS_JSON"])
cards = json.loads(os.environ["CARDS_JSON"])

def parse_due(s):
    if not s:
        return None
    try:
        # Trello: 2026-09-10T12:00:00.000Z
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

now = datetime.now(timezone.utc)
list_order = [l["id"] for l in lists]
list_name = {l["id"]: l.get("name", "") for l in lists}

def match_tag(c):
    if filter_mode == "all":
        return True
    for lb in c.get("labels") or []:
        if lb.get("name") == filter_tag:
            return True
    return False

tagged = [c for c in cards if match_tag(c)]

def card_view(c):
    due = c.get("due")
    due_complete = bool(c.get("dueComplete"))
    dt = parse_due(due) if due else None
    overdue = bool(dt and not due_complete and dt < now)
    return {
        "id": c.get("id"),
        "name": c.get("name"),
        "shortUrl": c.get("shortUrl"),
        "due": due,
        "dueComplete": due_complete,
        "overdue": overdue,
    }

by_list = {lid: [] for lid in list_order}
for c in tagged:
    lid = c.get("idList")
    if lid in by_list:
        by_list[lid].append(card_view(c))
    else:
        # лист закрыт/архивный — складываем отдельно
        by_list.setdefault(lid, []).append(card_view(c))

out_lists = []
overdue_all = []
no_due = 0
for l in lists:
    lid = l["id"]
    items = sorted(by_list.get(lid, []), key=lambda x: (x["due"] or ""))
    truncated = len(items) > limit
    shown = items[:limit]
    out_lists.append({
        "id": lid,
        "name": l.get("name", ""),
        "count": len(items),
        "truncated": truncated,
        "cards": shown,
    })
    for cv in items:
        if cv["overdue"]:
            overdue_all.append({"list": l.get("name", ""), **cv})
        if not cv["due"]:
            no_due += 1

overdue_all.sort(key=lambda x: (x["due"] or ""))
out = {
    "board": {"name": board, "id": board_id},
    "tag": filter_tag if filter_mode == "tag" else None,
    "filter": filter_mode,
    "fetched_at": now.isoformat().replace("+00:00", "Z"),
    "totals": {
        "tagged": len(tagged),
        "on_board": len(cards),
        "overdue": len(overdue_all),
        "no_due": no_due,
    },
    "lists": out_lists,
    "overdue": overdue_all,
}
print(json.dumps(out, ensure_ascii=False))
'
