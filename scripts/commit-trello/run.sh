#!/usr/bin/env bash
# run.sh — быстрый поиск связи коммитов ↔ Trello-карточек по трейлерам.
# Парсит git log без обращения к Trello API. Для ИИ — stdout только JSON.
# Использование:
#   bash .opencode/scripts/commit-trello/run.sh --card <shortUrl|shortLink|id> [--limit 20] [--json]
#   bash .opencode/scripts/commit-trello/run.sh --commit <hash> [--json]
#   bash .opencode/scripts/commit-trello/run.sh --all [--limit 50] [--json]
#   --card: https://trello.com/c/gFZbZhni | gFZbZhni | 6aac... (любой вариант)
#   --commit: хеш коммита (7+ символов)
#   --all: все коммиты с Trello/Closes
#   --json: только JSON на stdout (иначе JSON + hint на stderr)

set -euo pipefail

CARD=""; COMMIT=""; ALL=0; LIMIT=50; JSON_ONLY=0

usage() {
  echo "Usage: run.sh --card <shortUrl|id> [--limit N] | --commit <hash> | --all [--limit N] [--json]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card) CARD="${2:?--card требует URL/id}"; shift 2 ;;
    --commit) COMMIT="${2:?--commit требует hash}"; shift 2 ;;
    --all) ALL=1; shift ;;
    --limit) LIMIT="${2:?--limit требует число}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "--limit: число" >&2; exit 1; }

if [[ -n "$CARD" && -n "$COMMIT" ]]; then echo "укажи --card или --commit, не оба" >&2; exit 1; fi
if [[ -z "$CARD" && -z "$COMMIT" && "$ALL" -eq 0 ]]; then usage >&2; exit 1; fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

JSON_OUT=$(python3 - "$CARD" "$COMMIT" "$ALL" "$LIMIT" "$ROOT" << 'PY'
import re, subprocess, json, os, sys

card_raw = sys.argv[1] or ""
commit_hash = sys.argv[2] or ""
is_all = int(sys.argv[3])
limit = int(sys.argv[4])
root = sys.argv[5]

def normalize(raw):
    m = re.search(r'trello\.com/c/([a-zA-Z0-9]+)', raw)
    if m:
        return m.group(1)
    return re.sub(r'[^a-zA-Z0-9]', '', raw.strip().split('/')[-1]) if raw else ""

card_norm = normalize(card_raw) if card_raw else ""
TRELLO_RE = re.compile(r'^\s*(?:Trello|Closes|Fixes):\s*https?://trello\.com/c/([a-zA-Z0-9]+)', re.M | re.I)
TRELLO_SHORT_RE = re.compile(r'^\s*(?:Trello|Closes|Fixes):\s*([a-zA-Z0-9]{5,30})\s*$', re.M | re.I)

def parse_commit(msg):
    trello=[]
    closes=[]
    for m in TRELLO_RE.finditer(msg):
        v=m.group(1)
        url=f"https://trello.com/c/{v}"
        if url not in trello:
            trello.append(url)
        if m.group(0).strip().lower().startswith("closes") or m.group(0).strip().lower().startswith("fixes"):
            if url not in closes:
                closes.append(url)
    for m in TRELLO_SHORT_RE.finditer(msg):
        v=m.group(1)
        url=f"https://trello.com/c/{v}"
        if url not in trello:
            trello.append(url)
            # короткие без URL считаем только как Trello, не Closes, чтобы не дублировать
    return trello, closes

def git_log(args):
    cmd=["git","log","--all","--pretty=format:%H%x00%s%x00%b%x00%an%x00%ae%x00%aI%x1e"]+args
    out=subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=10)
    if out.returncode!=0:
        return []
    entries=[]
    for block in out.stdout.split("\x1e"):
        if not block.strip():
            continue
        parts=block.split("\x00")
        if len(parts)<6:
            continue
        h, subj, body, an, ae, ai = parts[:6]
        msg=subj+"\n\n"+body
        entries.append({"hash":h, "subject":subj, "body":body, "msg":msg, "author":an, "email":ae, "date":ai})
    return entries

result={}
if commit_hash:
    out=subprocess.run(["git","show","-s","--pretty=format:%H%x00%s%x00%b", commit_hash], cwd=root, capture_output=True, text=True, timeout=5)
    if out.returncode!=0:
        print(json.dumps({"error":"commit_not_found","hash":commit_hash}))
        sys.exit(1)
    parts=out.stdout.split("\x00")
    h, subj, body = (parts+["","",""])[:3]
    msg=subj+"\n\n"+body
    trello,closes=parse_commit(msg)
    result={"mode":"commit","hash":h,"subject":subj,"trello":trello,"closes":closes,"raw":msg}
    print(json.dumps(result, ensure_ascii=False, indent=2))
elif card_norm:
    logs=git_log([f"--grep=Trello", f"--grep=Closes", f"--grep={card_norm}", "--grep=trello.com/c"])
    if not logs:
        logs=git_log([f"-n", str(limit*5)])
    filtered=[]
    for e in logs:
        trello,closes=parse_commit(e["msg"])
        hit=False
        for url in trello+closes:
            if card_norm.lower() in url.lower():
                hit=True; break
        if hit:
            e["trello"]=trello; e["closes"]=closes
            filtered.append(e)
            if limit>0 and len(filtered)>=limit:
                break
    result={"mode":"card","card":card_norm,"card_url":f"https://trello.com/c/{card_norm}","limit":limit,"count":len(filtered),"commits":[{"hash":c["hash"],"short":c["hash"][:7],"subject":c["subject"],"date":c["date"],"author":c["author"],"trello":c["trello"],"closes":c["closes"]} for c in filtered]}
    print(json.dumps(result, ensure_ascii=False, indent=2))
else:
    logs=git_log([])
    filtered=[]
    for e in logs:
        trello,closes=parse_commit(e["msg"])
        if trello or closes:
            e["trello"]=trello; e["closes"]=closes
            filtered.append(e)
            if limit>0 and len(filtered)>=limit:
                break
    result={"mode":"all","limit":limit,"count":len(filtered),"commits":[{"hash":c["hash"],"short":c["hash"][:7],"subject":c["subject"],"date":c["date"],"author":c["author"],"trello":c["trello"],"closes":c["closes"]} for c in filtered]}
    print(json.dumps(result, ensure_ascii=False, indent=2))
PY
)

echo "$JSON_OUT"
if [[ $JSON_ONLY -eq 0 ]]; then
  python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print(f"hint: mode={j.get(\"mode\")} count={j.get(\"count\", len(j.get(\"trello\",[])))} — для ИИ: commits[].hash + trello[] — связь", file=sys.stderr)' "$JSON_OUT" 2>/dev/null || true
fi
