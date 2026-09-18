#!/usr/bin/env bash
# find_duplicates.sh — ищет семантические дубли Trello-карточек перед созданием новой.
# stdout — только JSON для ИИ, stderr — human hint.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/task-manager/find_duplicates.sh --title "<title>" [--desc "<desc>"] [--board "<name>"] [--threshold 0.6] [--json]
#   bash .opencode/scripts/task-manager/find_duplicates.sh --all [--board "<name>"] [--threshold 0.65] [--json]
#   --title: заголовок новой задачи (обязателен в режиме query)
#   --desc: описание новой задачи (опционально)
#   --all: искать дубли среди всех существующих карточек (для планировщика)
#   --threshold: 0.0-1.0, по умолчанию 0.6 (query) / 0.65 (all)
#   --json: только JSON на stdout

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/_common.sh"

TITLE=""; DESC=""; BOARD=""; THRESHOLD=""; ALL=0; JSON_ONLY=0

usage() {
  echo "Usage: find_duplicates.sh --title \"<title>\" [--desc \"<desc>\"] [--board \"<name>\"] [--threshold 0.6] [--json]"
  echo "       find_duplicates.sh --all [--board \"<name>\"] [--threshold 0.65] [--json]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="${2:?--title требует заголовок}"; shift 2 ;;
    --desc) DESC="${2:?--desc требует описание}"; shift 2 ;;
    --board) BOARD="${2:?--board требует имя доски}"; shift 2 ;;
    --threshold) THRESHOLD="${2:?--threshold требует число 0-1}"; shift 2 ;;
    --all) ALL=1; shift ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "find_duplicates: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "$ALL" -eq 0 && -z "$TITLE" ]]; then
  echo "find_duplicates: укажи --title или --all" >&2; usage >&2; exit 1
fi
if [[ -n "$THRESHOLD" ]]; then
  if ! python3 -c "v=float('$THRESHOLD'); assert 0 <= v <= 1" 2>/dev/null; then
    echo "find_duplicates: --threshold 0.0-1.0" >&2; exit 1
  fi
fi
if [[ -z "$THRESHOLD" ]]; then
  if [[ "$ALL" -eq 1 ]]; then THRESHOLD="0.65"; else THRESHOLD="0.5"; fi
fi

# дефолты из .trello-project
if [[ ! -f "$PROJECT_FILE" ]]; then
  python3 -c 'import json; print(json.dumps({"error":"no_project","hint":"нет .trello-project"}, ensure_ascii=False))'
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "./$PROJECT_FILE"
set +a
[[ -n "$BOARD" ]] || BOARD="${BOARD:-}"
if [[ -z "$BOARD" ]]; then
  python3 -c 'import json; print(json.dumps({"error":"no_board","hint":"нет доски"}, ensure_ascii=False))'
  exit 1
fi

FILTER_TAG="${NAME:-}"
FILTER_MODE="tag"
if [[ -z "$FILTER_TAG" ]]; then FILTER_MODE="all"; fi

require_creds
BOARD_ID="$(find_board_id "$BOARD")" || exit 1

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
trello_get "/boards/${BOARD_ID}/cards" --data-urlencode "filter=open" --data-urlencode "fields=name,desc,labels,shortUrl,url,idList" > "$TMPDIR/cards.json"
trello_get "/boards/${BOARD_ID}/lists" --data-urlencode "filter=open" --data-urlencode "fields=name" > "$TMPDIR/lists.json"

export TITLE DESC BOARD BOARD_ID THRESHOLD FILTER_TAG FILTER_MODE TMPDIR

JSON_OUT=$(python3 - << 'PY'
import json, os, re, sys, difflib
from collections import defaultdict

title = os.environ.get("TITLE","")
desc = os.environ.get("DESC","")
threshold = float(os.environ.get("THRESHOLD","0.6"))
filter_tag = os.environ.get("FILTER_TAG","")
filter_mode = os.environ.get("FILTER_MODE","tag")
tmpdir = os.environ.get("TMPDIR","/tmp")
is_all = os.environ.get("ALL","0") == "1"  # not set via env, check via TITLE empty
# Actually ALL passed as 1 via env? We set ALL via bash var, need to export
# Workaround: check if TITLE empty -> all mode

# reload ALL from bash: we didn't export ALL, use TITLE empty as proxy for all
# Better: pass via env ALL
ALL = os.environ.get("ALL","0") == "1"
if not os.environ.get("TITLE"):
    ALL = True

def load(p):
    with open(p, encoding="utf-8") as f: return json.load(f)

cards = load(os.path.join(tmpdir,"cards.json"))
lists = load(os.path.join(tmpdir,"lists.json"))
list_name = {l["id"]: l.get("name","") for l in lists}

def match_tag(c):
    if filter_mode=="all": return True
    for lb in c.get("labels") or []:
        if lb.get("name")==filter_tag: return True
    return False

# синонимы для семантики проекта (канонические -> варианты)
SYNONYMS = {
    "иконка": ["icon","favicon","лого","логотип","иконки","иконку","favicon"],
    "телефон": ["phone","tel","номер","телефона","телефону"],
    "форма": ["form","инпут","input","поле","формы","форму","формой"],
    "веб": ["web","frontend","сайт","лендинг","веба"],
    "фронт": ["frontend","web"],
    "мобил": ["mobile","app","android","apk","мобильного"],
    "баг": ["bug","фикс","fix","ошибка","бага","баги"],
}

def stem(tok):
    # простой стеммер для русского/английского: отрезаем частые окончания
    for suf in ["ирование","ование","ение","ание","ость","еский","анский","инский","ами","ями","ах","ях","ов","ев","ам","ем","ом","им","ым","их","ых","ую","юю","ая","яя","ое","ее","ые","ие","ой","ей","ий","ый","а","я","о","е","у","ю","ы","и","ь"]:
        if tok.endswith(suf) and len(tok) > len(suf)+3:
            return tok[:-len(suf)]
    return tok

def normalize(text):
    if not text: return set()
    t=text.lower()
    for canon, syns in SYNONYMS.items():
        for s in syns:
            if s in t:
                t=t.replace(s, canon)
    tokens=re.findall(r"[a-zа-яё0-9]{3,}", t)
    stop={"для","при","как","что","это","или","и","в","на","по","с","из","от","до","за","над","под","про","или","the","and","for","with","это","еще"}
    tokens=[tk for tk in tokens if tk not in stop]
    # стемминг
    tokens=[stem(tk) for tk in tokens]
    return set(tokens)

def jaccard(a,b):
    if not a and not b: return 1.0
    if not a or not b: return 0.0
    inter=len(a & b)
    union=len(a | b)
    return inter/union if union else 0.0

def seq_ratio(a,b):
    if not a or not b: return 0.0
    return difflib.SequenceMatcher(None, a.lower(), b.lower()).ratio()

filtered=[c for c in cards if match_tag(c)]

# обогащаем
for c in filtered:
    c["_tokens_title"]=normalize(c.get("name",""))
    c["_tokens_desc"]=normalize(c.get("desc",""))
    c["_list_name"]=list_name.get(c.get("idList"),"")

if ALL:
    # режим --all: ищем все пары дублей среди существующих
    pairs=[]
    n=len(filtered)
    for i in range(n):
        for j in range(i+1, n):
            a=filtered[i]; b=filtered[j]
            # пропускаем если уже в разных проектах? нет, фильтр уже по тегу
            # считаем схожесть по заголовкам + описаниям
            jt=jaccard(a["_tokens_title"], b["_tokens_title"])
            st=seq_ratio(a.get("name",""), b.get("name",""))
            # если заголовки короткие, jaccard важнее
            sim_title=max(jt, st)
            # описание: если оба пустые, не считаем
            jd=jaccard(a["_tokens_desc"], b["_tokens_desc"]) if a["_tokens_desc"] or b["_tokens_desc"] else 0
            # комбинируем: 70% заголовок, 30% описание (если есть)
            sim = 0.7*sim_title + 0.3*jd
            # бонус за общие ключевые стемы
            if sim < threshold:
                # если оба содержат икон/телефон/форм — считаем дублем
                a_tokens = a["_tokens_title"]
                b_tokens = b["_tokens_title"]
                has_icon = any("икон" in t for t in a_tokens) and any("икон" in t for t in b_tokens)
                has_phone = any("телефон" in t or "телеф" in t for t in a_tokens) and any("телефон" in t or "телеф" in t for t in b_tokens)
                has_form = any("форм" in t for t in a_tokens) and any("форм" in t for t in b_tokens)
                if has_icon or has_phone or has_form:
                    sim = max(sim, 0.65)
            if sim >= threshold:
                # определяем причину
                reason=[]
                if st >= threshold: reason.append(f"заголовок seq={st:.2f}")
                if jt >= threshold: reason.append(f"токены jaccard={jt:.2f}")
                if jd >= 0.5: reason.append(f"описание jaccard={jd:.2f}")
                if not reason: reason.append(f"комбинированная {sim:.2f}")
                pairs.append({
                    "a": {"id": a["id"], "name": a["name"], "shortUrl": a.get("shortUrl"), "list": a["_list_name"]},
                    "b": {"id": b["id"], "name": b["name"], "shortUrl": b.get("shortUrl"), "list": b["_list_name"]},
                    "similarity": round(sim,3),
                    "reason": ", ".join(reason)
                })
    # группируем пары в кластеры (связные компоненты)
    # для простоты возвращаем пары, агент сам решит
    out={"mode":"all","threshold":threshold,"count":len(pairs),"pairs":sorted(pairs, key=lambda x: -x["similarity"])[:20]}
    print(json.dumps(out, ensure_ascii=False, indent=2))
else:
    # режим query: новая задача vs существующие
    q_tokens_title=normalize(title)
    q_tokens_desc=normalize(desc)
    q_all_tokens=q_tokens_title | q_tokens_desc
    duplicates=[]
    for c in filtered:
        jt=jaccard(q_tokens_title, c["_tokens_title"])
        st=seq_ratio(title, c.get("name",""))
        sim_title=max(jt, st)
        jd=jaccard(q_tokens_desc, c["_tokens_desc"]) if q_tokens_desc or c["_tokens_desc"] else 0
        # если запрос без desc, jd=0, не влияем
        if q_tokens_desc:
            sim = 0.6*sim_title + 0.4*jd
        else:
            sim = sim_title
        # семантический бонус: икон/телефон/форм — считаем дублем даже при низкой jaccard
        if any("икон" in t for t in q_tokens_title) and any("икон" in t for t in c["_tokens_title"]):
            sim = max(sim, 0.75)
        if any("телефон" in t or "телеф" in t for t in q_tokens_title) and any("телефон" in t or "телеф" in t for t in c["_tokens_title"]):
            sim = max(sim, 0.75)
        if any("форм" in t for t in q_tokens_title) and any("форм" in t for t in c["_tokens_title"]):
            sim = max(sim, 0.70)
        if sim >= threshold:
            # определяем matched_on
            matched_on=[]
            if st >= 0.6: matched_on.append("title_seq")
            if jt >= 0.5: matched_on.append("title_tokens")
            if jd >= 0.5: matched_on.append("desc")
            duplicates.append({
                "id": c["id"],
                "name": c["name"],
                "shortUrl": c.get("shortUrl"),
                "url": c.get("url"),
                "list": c["_list_name"],
                "similarity": round(sim,3),
                "reason": f"title seq={st:.2f}, jaccard={jt:.2f}" + (f", desc jaccard={jd:.2f}" if q_tokens_desc else ""),
                "matched_on": matched_on,
                "desc_len": len(c.get("desc") or "")
            })
    duplicates.sort(key=lambda x: -x["similarity"])
    out={"mode":"query","query":{"title":title,"desc":desc[:200]},"threshold":threshold,"count":len(duplicates),"duplicates":duplicates[:10]}
    print(json.dumps(out, ensure_ascii=False, indent=2))
PY
)

echo "$JSON_OUT"
if [[ "${JSON_ONLY:-0}" -eq 0 ]]; then
  JSON_OUT="$JSON_OUT" python3 << 'PY' 2>&1 || true
import json, os, sys
j=json.loads(os.environ["JSON_OUT"])
if j.get("mode")=="query":
    print(f"find_duplicates: query='{j['query']['title'][:40]}' threshold={j['threshold']} found={j['count']}", file=sys.stderr)
    for d in j["duplicates"][:3]:
        print(f"  -> {d['name'][:60]} | {d['shortUrl']} | sim={d['similarity']}", file=sys.stderr)
    if j["count"]>0:
        print(f"hint: не создавай новую задачу — вынеси ссылку на {j['duplicates'][0]['shortUrl']} в описание/комментарий", file=sys.stderr)
else:
    print(f"find_duplicates: all mode threshold={j['threshold']} pairs={j['count']}", file=sys.stderr)
    for p in j["pairs"][:3]:
        print(f"  {p['a']['name'][:40]} <-> {p['b']['name'][:40]} sim={p['similarity']} — {p['reason']}", file=sys.stderr)
PY
fi
