#!/usr/bin/env bash
# run.sh — поиск коммитов по списку задач Trello. Unix-философия: одна задача —
# джойн «задачи → коммиты с трейлерами Trello:/Closes:».
# Не ищет Trello сам — берёт список задач из audit/dump или файла, не гадает.
# stdout — только JSON для ИИ, stderr — hint. Требует git, без сети к Trello
# кроме audit-части (если берёт задачи с доски).
#
# Использование (из корня consumer-репо, где лежит .git и .devbox-project):
#   bash .opencode/scripts/task-commits/run.sh [--board "<name>"] [--tag "<tag>" | --all] [--limit N] [--log-limit M] [--json]
#   bash .opencode/scripts/task-commits/run.sh --tasks-file <audit.json|dump.json> [--log-limit M] [--json]
#   bash .opencode/scripts/task-commits/run.sh --tasks-json '<json>' [--log-limit M] --json  (или stdin)
#
#   --board — точное имя доски (по умолчанию BOARD из .devbox-project)
#   --tag/--all — фильтр метки (по умолчанию NAME из .devbox-project, --all — все карточки доски)
#   --limit — макс. карточек на лист для audit (по умолчанию 50, для задач без лимита 0 не нужен — audit пагинирует)
#   --log-limit — сколько последних коммитов сканировать на трейлеры (по умолчанию 100, кап 500)
#   --tasks-file — готовый JSON с задачами (audit.json, dump.json или массив cards) вместо запроса к Trello
#   --tasks-json — inline JSON (или stdin если пусто и нет --board/--tasks-file)
#   --json — только JSON на stdout
#
# Выход: {board,filter,fetched_at,tasks{count,cards[]},commits{count,log_limit,items[]},by_task{SHORT->{task,commits[],closes}},tasks_without_commits[],commits_without_task[]}
# Карточка матчится по shortUrl/shortLink/id → short (трейлер Trello: https://trello.com/c/<SHORT>).
set -euo pipefail
HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/../task-manager/_common.sh"

BOARD=""; TAG_OVERRIDE=""; SHOW_ALL=0; LIMIT=50; LOG_LIMIT=100; TASKS_FILE=""; TASKS_JSON=""; JSON_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) BOARD="${2:?--board требует имя}"; shift 2 ;;
    --tag) TAG_OVERRIDE="${2:?--tag требует значение}"; shift 2 ;;
    --all) SHOW_ALL=1; shift ;;
    --limit) LIMIT="${2:?--limit N}"; shift 2 ;;
    --log-limit) LOG_LIMIT="${2:?--log-limit N}"; shift 2 ;;
    --tasks-file) TASKS_FILE="${2:?--tasks-file <path>}"; shift 2 ;;
    --tasks-json) TASKS_JSON="${2:-}"; shift 2; if [[ -z "$TASKS_JSON" && ! -t 0 ]]; then TASKS_JSON="$(cat)"; fi ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) sed -n '1,70p' "$0"; exit 0 ;;
    *) echo "task-commits: неизвестный аргумент '$1'" >&2; exit 1 ;;
  esac
done
[[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "--limit: число" >&2; exit 1; }
[[ "$LOG_LIMIT" =~ ^[0-9]+$ ]] || { echo "--log-limit: число" >&2; exit 1; }
if [[ "$LOG_LIMIT" -gt 500 ]]; then LOG_LIMIT=500; fi
if [[ -n "$TASKS_FILE" && -n "$TASKS_JSON" ]]; then echo "укажи --tasks-file или --tasks-json, не оба" >&2; exit 1; fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AUDIT_JSON=""
TASKS_SOURCE="board"
if [[ -n "$TASKS_FILE" ]]; then
  [[ -f "$TASKS_FILE" ]] || { echo "нет файла $TASKS_FILE" >&2; exit 1; }
  AUDIT_JSON="$(cat "$TASKS_FILE")"
  TASKS_SOURCE="file:$TASKS_FILE"
elif [[ -n "$TASKS_JSON" ]]; then
  AUDIT_JSON="$TASKS_JSON"
  TASKS_SOURCE="inline"
elif [[ -t 0 && -z "$BOARD" && -z "$TASKS_FILE" ]]; then
  # нет ни файла ни stdin — идём в Trello как audit
  :
else
  # stdin с задачами?
  if [[ ! -t 0 ]]; then
    _stdin="$(cat || true)"
    if [[ -n "$_stdin" && "$_stdin" == *"shortUrl"* ]]; then
      AUDIT_JSON="$_stdin"
      TASKS_SOURCE="stdin"
    fi
  fi
fi

# Если задачи не переданы явно — тянем audit с доски (как audit.sh, BOARD дефолт из .devbox-project)
if [[ -z "$AUDIT_JSON" ]]; then
  _audit_args=()
  [[ -n "$BOARD" ]] && _audit_args+=(--board "$BOARD")
  [[ -n "$TAG_OVERRIDE" ]] && _audit_args+=(--tag "$TAG_OVERRIDE")
  [[ "$SHOW_ALL" -eq 1 ]] && _audit_args+=(--all)
  _audit_args+=(--limit "$LIMIT")
  AUDIT_JSON="$(bash "$HERE/../task-manager/audit.sh" "${_audit_args[@]}" 2>/dev/null || true)"
  # audit.sh уже вернул JSON или error; если error — прокидываем
  if echo "$AUDIT_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "error" not in d else 1)' 2>/dev/null; then
    :
  else
    echo "$AUDIT_JSON"
    if [[ $JSON_ONLY -eq 0 ]]; then echo "hint: audit вернул error — проверь BOARD/.devbox-project" >&2; fi
    exit 1
  fi
  TASKS_SOURCE="audit:board=${BOARD:-$PROJECT_FILE}"
fi

export AUDIT_JSON LOG_LIMIT ROOT TASKS_SOURCE
JSON_OUT=$(python3 - << 'PY'
import json, os, re, subprocess, sys
audit_raw = os.environ.get("AUDIT_JSON","")
log_limit = int(os.environ.get("LOG_LIMIT","100"))
root = os.environ.get("ROOT",".")
tasks_source = os.environ.get("TASKS_SOURCE","")

def load_tasks(raw):
    try:
        d = json.loads(raw)
    except Exception as e:
        print(json.dumps({"error":"bad_tasks_json","hint":str(e)}, ensure_ascii=False))
        sys.exit(1)
    # audit.json: {board, lists:[{cards:[]}], ...}
    # dump.json: {lists:[{cards:[]}]} или {cards:[]}
    # file может быть массивом cards
    cards = []
    board = d.get("board", {"name": None, "id": None})
    fetched_at = d.get("fetched_at")
    flt = d.get("filter")
    if isinstance(d, list):
        for c in d:
            cards.append({"id": c.get("id"), "name": c.get("name"), "shortUrl": c.get("shortUrl"), "list": c.get("list",""), "due": c.get("due"), "dueComplete": c.get("dueComplete", False)})
    elif "lists" in d:
        for lst in d.get("lists", []):
            lname = lst.get("name","")
            for c in lst.get("cards", []):
                cards.append({"id": c.get("id"), "name": c.get("name"), "shortUrl": c.get("shortUrl"), "list": lname, "due": c.get("due"), "dueComplete": c.get("dueComplete", False), "blocked_by": c.get("blocked_by", [])})
        board = d.get("board", board)
        fetched_at = d.get("fetched_at", fetched_at)
        flt = d.get("filter", flt)
    elif "cards" in d:
        for c in d.get("cards", []):
            cards.append({"id": c.get("id"), "name": c.get("name"), "shortUrl": c.get("shortUrl"), "list": c.get("list",""), "due": c.get("due")})
    else:
        # одиночная карточка
        if "shortUrl" in d:
            cards.append({"id": d.get("id"), "name": d.get("name"), "shortUrl": d.get("shortUrl"), "list": d.get("list","")})
    return cards, board, fetched_at, flt

cards, board, fetched_at, flt = load_tasks(audit_raw)

def short_of(url_or_id):
    if not url_or_id: return None
    m = re.search(r'trello\.com/c/([A-Za-z0-9]+)', url_or_id)
    if m: return m.group(1)
    s = re.sub(r'[^A-Za-z0-9]', '', url_or_id.split('/')[-1].strip())
    return s if s else None

for c in cards:
    c["short"] = short_of(c.get("shortUrl") or c.get("id") or "")

# индекс задач по short
by_short_task = {}
for c in cards:
    s = c.get("short")
    if s: by_short_task[s] = c

# git log с трейлерами
TRELLO_RE = re.compile(r'^\s*(?:Trello|Closes|Fixes):\s*https?://trello\.com/c/([A-Za-z0-9]+)', re.M | re.I)
SHORT_RE  = re.compile(r'^\s*(?:Trello|Closes|Fixes):\s*([A-Za-z0-9]{5,30})\s*$', re.M | re.I)
def parse_trailers(msg):
    trello, closes = [], []
    for m in TRELLO_RE.finditer(msg):
        v=m.group(1); url=f"https://trello.com/c/{v}"
        if url not in trello: trello.append(url)
        if m.group(0).strip().lower().startswith("closes") or m.group(0).strip().lower().startswith("fixes"):
            if url not in closes: closes.append(url)
    for m in SHORT_RE.finditer(msg):
        v=m.group(1); url=f"https://trello.com/c/{v}"
        if url not in trello: trello.append(url)
    return trello, closes

def sh(cmd, cwd=root):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=10)
    return p

log_args = ["git","log","--pretty=format:%H%x00%s%x00%b%x00%an%x00%ae%x00%aI%x00%D%x1e"]
if log_limit>0: log_args.extend(["-n", str(log_limit)])
log_p = sh(log_args)
commits = []
if log_p.returncode==0:
    for block in log_p.stdout.split("\x1e"):
        block=block.strip("\n")
        if not block.strip(): continue
        parts=block.split("\x00")
        if len(parts)<7: continue
        h, subj, body, an, ae, ai, dec = parts[:7]
        h=h.strip()
        msg=subj+"\n\n"+body
        trello, closes = parse_trailers(msg)
        shorts=[short_of(u) for u in trello]
        shorts=[s for s in shorts if s]
        closes_shorts=[short_of(u) for u in closes]
        commits.append({"hash":h,"short":h[:7],"subject":subj.strip(),"body":body.strip(),"author":an,"email":ae,"date":ai,"decorations":dec.strip(),"trello":trello,"closes":closes,"shorts":shorts,"closes_shorts":closes_shorts})

# джойн
by_task = {}
for s, task in by_short_task.items():
    by_task[s] = {"task": task, "commits": [], "closes": False}

commits_without_task = []
for c in commits:
    hit=False
    for s in c["shorts"]:
        if s in by_task:
            by_task[s]["commits"].append(c)
            if s in c["closes_shorts"]:
                by_task[s]["closes"]=True
            hit=True
    if not hit and c["trello"]:
        # коммит ссылается на карточку не из списка задач (другая доска/тег)
        commits_without_task.append(c)
    elif not c["trello"]:
        # без трейлера — не относим
        pass

tasks_without_commits = [by_task[s]["task"] for s in by_task if not by_task[s]["commits"]]

out = {
    "board": board,
    "filter": flt,
    "fetched_at": fetched_at,
    "tasks_source": tasks_source,
    "tasks": {"count": len(cards), "cards": cards},
    "commits": {"count": len(commits), "log_limit": log_limit, "items": commits},
    "by_task": by_task,
    "tasks_without_commits": tasks_without_commits,
    "commits_without_task": commits_without_task,
}
# компактные счётчики
out["_summary"] = {"tasks": len(cards), "commits_scanned": len(commits), "tasks_with_commits": len([s for s in by_task if by_task[s]["commits"]]), "tasks_without_commits": len(tasks_without_commits), "commits_linked_to_list": len(commits)-len(commits_without_task)}
print(json.dumps(out, ensure_ascii=False))
PY
)
echo "$JSON_OUT"
if [[ $JSON_ONLY -eq 0 ]]; then
  python3 -c 'import json,sys; j=json.loads(sys.argv[1]); s=j.get("_summary",{}); print(f"hint: tasks={s.get(\"tasks\",0)} with_commits={s.get(\"tasks_with_commits\",0)} without={s.get(\"tasks_without_commits\",0)} commits_scanned={s.get(\"commits_scanned\",0)}", file=sys.stderr)' "$JSON_OUT" 2>/dev/null || true
fi
