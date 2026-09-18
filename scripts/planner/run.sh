#!/usr/bin/env bash
# run.sh — планировщик батчей для Trello. Находит лёгкие задачи, которые можно делать пачкой,
# и проверяет, что в Trello есть инструкция как фиксить.
# stdout — только JSON для ИИ, stderr — human hint.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/planner/run.sh [--board "<name>"] [--tag "<tag>" | --all] [--limit <N>] [--json]
#   --board: точное имя доски (по умолчанию BOARD из .trello-project)
#   --tag: метка проекта (по умолчанию NAME), --all — без фильтра
#   --limit: макс. карточек (по умолчанию 100, 0 = без лимита)
#   --json: только JSON на stdout

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/../task-manager/_common.sh"

BOARD=""; TAG_OVERRIDE=""; SHOW_ALL=0; LIMIT=100; JSON_ONLY=0

usage() {
  echo "Usage: planner/run.sh [--board \"<name>\"] [--tag \"<tag>\" | --all] [--limit <N>] [--json]"
  echo "  Печатает JSON: batches (лёгкие пачкой), singles, incomplete (нет инструкции как фиксить)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board) BOARD="${2:?--board требует имя доски}"; shift 2 ;;
    --tag) TAG_OVERRIDE="${2:?--tag требует значение}"; shift 2 ;;
    --all) SHOW_ALL=1; shift ;;
    --limit) LIMIT="${2:?--limit требует число}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "planner: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "planner: --limit только неотрицательное число" >&2; exit 1; }

if [[ ! -f "$PROJECT_FILE" ]]; then
  python3 -c 'import json,sys; print(json.dumps({"error":"no_project","hint":sys.argv[1]}, ensure_ascii=False))' "нет $PROJECT_FILE — сначала: bash .opencode/scripts/task-manager/init.sh"
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "./$PROJECT_FILE"
set +a

[[ -n "$BOARD" ]] || BOARD="${BOARD:-}"
if [[ -z "$BOARD" ]]; then
  python3 -c 'import json; print(json.dumps({"error":"no_board","hint":"нет доски: передай --board \"<точное имя>\" (см. boards.sh)"}, ensure_ascii=False))'
  exit 1
fi

FILTER_TAG=""; FILTER_MODE="tag"
if [[ "$SHOW_ALL" -eq 1 ]]; then FILTER_MODE="all"
elif [[ -n "$TAG_OVERRIDE" ]]; then FILTER_TAG="$TAG_OVERRIDE"
else FILTER_TAG="${NAME:-}"
fi
if [[ "$FILTER_MODE" == "tag" && -z "$FILTER_TAG" ]]; then
  python3 -c 'import json; print(json.dumps({"error":"no_tag","hint":".trello-project без NAME — перезапусти init.sh --force или передай --tag/--all"}, ensure_ascii=False))'
  exit 1
fi

require_creds

BOARD_ID="$(find_board_id "$BOARD")" || exit 1

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
trello_get "/boards/${BOARD_ID}/lists" --data-urlencode "filter=open" --data-urlencode "fields=name" > "$TMPDIR/lists.json"
trello_get "/boards/${BOARD_ID}/cards" --data-urlencode "filter=open" --data-urlencode "fields=name,desc,due,dueComplete,idList,labels,shortUrl,url,idMembers,idChecklists" > "$TMPDIR/cards.json"
trello_get "/boards/${BOARD_ID}/checklists" --data-urlencode "fields=name,idCard" > "$TMPDIR/checklists.json" 2>/dev/null || echo "[]" > "$TMPDIR/checklists.json"

export FILTER_TAG FILTER_MODE BOARD BOARD_ID LIMIT TMPDIR

JSON_OUT=$(python3 - << 'PY'
import json, os, re, sys
from datetime import datetime, timezone

board = os.environ["BOARD"]
board_id = os.environ["BOARD_ID"]
filter_tag = os.environ.get("FILTER_TAG","")
filter_mode = os.environ.get("FILTER_MODE","tag")
limit = int(os.environ.get("LIMIT","100"))
tmpdir = os.environ.get("TMPDIR","/tmp")

def load(p):
    with open(p, encoding="utf-8") as f: return json.load(f)

lists = load(os.path.join(tmpdir,"lists.json"))
cards = load(os.path.join(tmpdir,"cards.json"))
try:
    checklists = load(os.path.join(tmpdir,"checklists.json"))
except: checklists=[]

list_name = {l["id"]: l.get("name","") for l in lists}
checks_by_card={}
for cl in checklists:
    cid=cl.get("idCard")
    if not cid: continue
    checks_by_card.setdefault(cid, []).append(cl)

def match_tag(c):
    if filter_mode=="all": return True
    for lb in c.get("labels") or []:
        if lb.get("name")==filter_tag: return True
    return False

BLOCKED_RE = re.compile(r"(?im)^\s*blocked\s+by\s*:\s*(.+?)\s*$")
URL_RE = re.compile(r"https?://[^\s,)]+")
def parse_blocked(desc):
    found=[]
    for m in BLOCKED_RE.finditer(desc or ""):
        urls=URL_RE.findall(m.group(1))
        if urls: found.extend(urls)
        elif m.group(1).strip(): found.append(m.group(1).strip())
    return found

def has_fix_instructions(desc):
    if not desc or len(desc.strip()) < 50:
        return False
    low=desc.lower()
    has_sections = any(k in low for k in ["что сделать","как исправить","как фиксить","шаг","критерии","контекст","## что","## как"])
    has_list = bool(re.search(r"(^|\n)\s*(\d+\.|[-*])\s+", desc))
    return has_sections or has_list

def area_of(title):
    t=title.lower()
    if any(k in t for k in ["фронт","веб","landing","сайт","форма","input","email"]): return "frontend"
    if any(k in t for k in ["иконка","favicon","mobile","мобил","android","apk","app"]): return "mobile"
    if any(k in t for k in ["server","api","бд","database","инфра","deploy"]): return "backend"
    if any(k in t for k in ["spec","доки","readme","speka","doc"]): return "docs"
    if "s3" in t or "r2" in t: return "infra"
    return "other"

filtered=[c for c in cards if match_tag(c)]
if limit>0 and len(filtered)>limit:
    filtered=filtered[:limit]

enriched=[]
for c in filtered:
    desc=c.get("desc","") or ""
    cid=c.get("id")
    checks=checks_by_card.get(cid, [])
    total_items=sum(len(cl.get("checkItems") or []) for cl in checks)
    blocked=parse_blocked(desc)
    has_fix=has_fix_instructions(desc)
    is_light = (not blocked) and (total_items <=3) and (len(desc) < 2000) and (len(desc) > 0) and (total_items <=2 or has_fix)
    heavy_keywords=["spec:","server:","монетизация","vision","rxnorm","aiogram","workflow","сборки"]
    if any(k.lower() in c.get("name","").lower() for k in heavy_keywords):
        if "иконка" not in c.get("name","").lower() and "favicon" not in c.get("name","").lower():
            is_light=False
    if not has_fix:
        is_light=False
    enriched.append({
        "id": cid,
        "name": c.get("name"),
        "shortUrl": c.get("shortUrl"),
        "url": c.get("url"),
        "list": {"id": c.get("idList"), "name": list_name.get(c.get("idList"),"")},
        "labels": c.get("labels") or [],
        "desc_len": len(desc),
        "has_fix": has_fix,
        "blocked_by": blocked,
        "checks": total_items,
        "is_light": is_light,
        "area": area_of(c.get("name","")),
        "due": c.get("due"),
    })

from collections import defaultdict
light=[e for e in enriched if e["is_light"] and e["has_fix"] and not e["blocked_by"]]
light_by_area=defaultdict(list)
for e in light:
    key=(e["area"], e["list"]["name"])
    light_by_area[key].append(e)

batches=[]
batch_id=1
for (area, lst), items in light_by_area.items():
    items.sort(key=lambda x: x["name"])
    for i in range(0, len(items), 3):
        chunk=items[i:i+3]
        if len(chunk) <2:
            continue
        safe_area=re.sub(r'[^a-z0-9]+','-', area.lower()).strip('-') or "other"
        safe_list=re.sub(r'[^a-z0-9]+','-', lst.lower()).strip('-')[:20]
        branch=f"chore/batch-{safe_area}-{safe_list}-{batch_id}"
        batches.append({
            "id": batch_id,
            "area": area,
            "list": lst,
            "branch": branch,
            "cards": chunk,
            "reason": f"лёгкие ({len(chunk)}) в '{lst}' area={area}, без зависимостей, есть инструкция как фиксить — можно одним PR/worktree"
        })
        batch_id+=1
        for ch in chunk: ch["_batched"]=True

singles=[]
for e in enriched:
    if e.get("_batched"): continue
    if e["is_light"] and e["has_fix"]:
        singles.append(e)

incomplete=[e for e in enriched if not e["has_fix"]]
heavy=[e for e in enriched if not e["is_light"] and e["has_fix"]]

out={
    "board": {"name": board, "id": board_id},
    "tag": filter_tag if filter_mode=="tag" else None,
    "filter": filter_mode,
    "fetched_at": datetime.now(timezone.utc).isoformat().replace("+00:00","Z"),
    "totals": {"matched": len(filtered), "light": len(light), "batches": len(batches), "singles": len(singles), "incomplete": len(incomplete), "heavy": len(heavy)},
    "batches": batches,
    "singles": singles,
    "incomplete": incomplete,
    "heavy": heavy,
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
)

echo "$JSON_OUT"
if [[ "${JSON_ONLY:-0}" -eq 0 ]]; then
  JSON_OUT="$JSON_OUT" python3 << 'PY' 2>&1 || true
import json, os, sys
j=json.loads(os.environ["JSON_OUT"])
print(f"planner: matched={j['totals']['matched']} light={j['totals']['light']} batches={j['totals']['batches']} incomplete={j['totals']['incomplete']} — для ИИ: batches[].branch + cards[].shortUrl", file=sys.stderr)
for b in j["batches"]:
    names=", ".join([c["name"][:40] for c in b["cards"]])
    print(f"  batch {b['id']} [{b['area']}/{b['list']}] {b['branch']} => {names}", file=sys.stderr)
for c in j["incomplete"][:5]:
    print(f"  incomplete: {c['name'][:50]} | {c['shortUrl']} — нет инструкции как фиксить (desc={c['desc_len']})", file=sys.stderr)
PY
fi
