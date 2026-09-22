#!/usr/bin/env bash
# dump.sh — выводит все задачи доски со всей информацией, JSON для ИИ-агента.
#
# Первичный потребитель — ИИ-агент (task-manager / task-audit), не человек:
# stdout — только чистый JSON, без markdown/заголовков. Включает все поля
# карточки, чеки, участников, метки — чтобы агент мог анализировать без доп. запросов.
# Никаких мутаций: только GET.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/task-manager/dump.sh [--board "<name>"] [--tag "<tag>" | --all] [--limit <N>]
#
#   --board  Точное имя доски (см. boards.sh). Если не указан — берётся BOARD из .devbox-project.
#   --tag    Фильтр по метке (по умолчанию NAME из .devbox-project). --all — без фильтра.
#   --limit  Макс. карточек в выдаче (по умолчанию 100, 0 = без лимита).
#   Примеры:
#     bash .opencode/scripts/task-manager/dump.sh
#     bash .opencode/scripts/task-manager/dump.sh --board "Aleksei — Work Hub" --all --limit 200

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh"

BOARD=""; TAG_OVERRIDE=""; SHOW_ALL=0; LIMIT=100

usage() {
  echo "Usage: dump.sh [--board \"<board name>\"] [--tag \"<tag>\" | --all] [--limit <N>]"
  echo "  Печатает в stdout только JSON: board/tag/cards с полной информацией."
}

err_json() {
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

[[ "$LIMIT" =~ ^[0-9]+$ ]] || { err_json "bad_limit" "--limit: только неотрицательное число"; exit 1; }

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

# Собираем данные: листы, карточки (open), чек-листы доски, участники доски
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
trello_get "/boards/${BOARD_ID}/lists" --data-urlencode "filter=open" --data-urlencode "fields=name" > "$TMPDIR/lists.json"
trello_get "/boards/${BOARD_ID}/cards" \
  --data-urlencode "filter=open" \
  --data-urlencode "fields=name,desc,due,dueComplete,idList,labels,shortUrl,url,idMembers,idChecklists,dateLastActivity,closed,pos,badges" > "$TMPDIR/cards.json"
trello_get "/boards/${BOARD_ID}/checklists" --data-urlencode "fields=name,idCard" > "$TMPDIR/checklists.json" 2>/dev/null || echo "[]" > "$TMPDIR/checklists.json"
trello_get "/boards/${BOARD_ID}/members" --data-urlencode "fields=fullName,username,id" > "$TMPDIR/members.json" 2>/dev/null || echo "[]" > "$TMPDIR/members.json"

export FILTER_TAG FILTER_MODE BOARD BOARD_ID LIMIT TMPDIR
python3 -c '
import json, os, re, sys
from datetime import datetime, timezone

board = os.environ["BOARD"]
board_id = os.environ["BOARD_ID"]
filter_tag = os.environ.get("FILTER_TAG", "")
filter_mode = os.environ.get("FILTER_MODE", "tag")
limit = int(os.environ.get("LIMIT", "100"))
tmpdir = os.environ.get("TMPDIR", "/tmp")

def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

lists = load_json(os.path.join(tmpdir, "lists.json"))
cards = load_json(os.path.join(tmpdir, "cards.json"))
try:
    checklists = load_json(os.path.join(tmpdir, "checklists.json"))
except:
    checklists = []
try:
    members = load_json(os.path.join(tmpdir, "members.json"))
except:
    members = []

def parse_due(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except:
        return None

now = datetime.now(timezone.utc)
list_name = {l["id"]: l.get("name","") for l in lists}
member_by_id = {m["id"]: {"id": m["id"], "username": m.get("username"), "fullName": m.get("fullName")} for m in members}

# Группируем чеки по карточке
checks_by_card = {}
for cl in checklists:
    cid = cl.get("idCard")
    if not cid:
        continue
    entry = {
        "id": cl.get("id"),
        "name": cl.get("name"),
        "items": [
            {
                "id": it.get("id"),
                "name": it.get("name"),
                "state": it.get("state"),
                "due": it.get("due"),
                "pos": it.get("pos"),
                "member": it.get("idMember"),
            } for it in cl.get("checkItems", [])
        ]
    }
    checks_by_card.setdefault(cid, []).append(entry)

def match_tag(c):
    if filter_mode == "all":
        return True
    for lb in c.get("labels") or []:
        if lb.get("name") == filter_tag:
            return True
    return False

BLOCKED_RE = re.compile(r"(?im)^\s*blocked\s+by\s*:\s*(.+?)\s*$")
URL_RE = re.compile(r"https?://[^\s,)]+")
def parse_blocked(desc):
    found = []
    for m in BLOCKED_RE.finditer(desc or ""):
        urls = URL_RE.findall(m.group(1))
        if urls:
            found.extend(urls)
        elif m.group(1).strip():
            found.append(m.group(1).strip())
    return found

filtered = [c for c in cards if match_tag(c)]
# Сортировка: по списку (порядок листов), затем по pos
list_order = {lid: idx for idx, lid in enumerate([l["id"] for l in lists])}
filtered.sort(key=lambda c: (list_order.get(c.get("idList"), 9999), c.get("pos", 0)))

if limit > 0 and len(filtered) > limit:
    truncated = True
    shown = filtered[:limit]
else:
    truncated = False
    shown = filtered

out_cards = []
for c in shown:
    dt = parse_due(c.get("due"))
    overdue = bool(dt and not c.get("dueComplete") and dt < now)
    cid = c.get("id")
    out_cards.append({
        "id": cid,
        "name": c.get("name"),
        "desc": c.get("desc", ""),
        "url": c.get("url"),
        "shortUrl": c.get("shortUrl"),
        "list": {"id": c.get("idList"), "name": list_name.get(c.get("idList"), "")},
        "pos": c.get("pos"),
        "labels": c.get("labels") or [],
        "due": c.get("due"),
        "dueComplete": bool(c.get("dueComplete")),
        "overdue": overdue,
        "blocked_by": parse_blocked(c.get("desc")),
        "members": [member_by_id[mid] for mid in (c.get("idMembers") or []) if mid in member_by_id],
        "memberIds": c.get("idMembers") or [],
        "checklists": checks_by_card.get(cid, []),
        "checklistIds": c.get("idChecklists") or [],
        "badges": c.get("badges") or {},
        "dateLastActivity": c.get("dateLastActivity"),
        "closed": bool(c.get("closed")),
    })

out = {
    "board": {"name": board, "id": board_id},
    "tag": filter_tag if filter_mode == "tag" else None,
    "filter": filter_mode,
    "fetched_at": now.isoformat().replace("+00:00", "Z"),
    "totals": {
        "matched": len(filtered),
        "on_board": len(cards),
        "returned": len(out_cards),
        "truncated": truncated,
        "lists": len(lists),
    },
    "lists": [{"id": l["id"], "name": l.get("name","")} for l in lists],
    "cards": out_cards,
}
print(json.dumps(out, ensure_ascii=False))
'
