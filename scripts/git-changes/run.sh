#!/usr/bin/env bash
# run.sh — git-изменения в LLM-формате. Только JSON на stdout, hint на stderr.
# Собирает dirty tree + последние коммиты с Trello-трейлерами, чтобы аудит
# не пропускал «сделали, но не закоммитили/не отметили».
#
# Использование (из корня consumer-репо, где лежит .git):
#   bash .opencode/scripts/git-changes/run.sh [--limit 20] [--since "2 weeks ago"] [--branch main]
#   [--limit N] — макс. коммитов (по умолчанию 20, 0 = без лимита, но кап 100)
#   [--since <git-log-since>] — напр. "2 weeks ago", "2026-09-01"
#   [--branch <name>] — ветка для log (по умолчанию HEAD/текущая)
#   --json — только JSON (иначе JSON на stdout + hint на stderr)
set -euo pipefail
LIMIT=20
SINCE=""
BRANCH=""
JSON_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="${2:?--limit N}"; shift 2 ;;
    --since) SINCE="${2:?--since <expr>}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch <name>}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
    *) echo "git-changes: неизвестный аргумент '$1'" >&2; exit 1 ;;
  esac
done
[[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "--limit: число" >&2; exit 1; }
if [[ "$LIMIT" -gt 100 ]]; then LIMIT=100; fi
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
JSON_OUT=$(python3 - "$ROOT" "$LIMIT" "$SINCE" "$BRANCH" << 'PY'
import json, re, subprocess, sys
root = sys.argv[1]
limit = int(sys.argv[2])
since = sys.argv[3]
branch = sys.argv[4]

def sh(cmd, cwd=root, timeout=10):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return p

TRELLO_RE = re.compile(r'^\s*(?:Trello|Closes|Fixes):\s*https?://trello\.com/c/([a-zA-Z0-9]+)', re.M | re.I)
SHORT_RE  = re.compile(r'^\s*(?:Trello|Closes|Fixes):\s*([a-zA-Z0-9]{5,30})\s*$', re.M | re.I)

def parse_trailers(msg):
    trello, closes = [], []
    for m in TRELLO_RE.finditer(msg):
        v = m.group(1); url = f"https://trello.com/c/{v}"
        if url not in trello: trello.append(url)
        if m.group(0).strip().lower().startswith("closes") or m.group(0).strip().lower().startswith("fixes"):
            if url not in closes: closes.append(url)
    for m in SHORT_RE.finditer(msg):
        v = m.group(1); url = f"https://trello.com/c/{v}"
        if url not in trello: trello.append(url)
    return trello, closes

status_p = sh(["git","status","--porcelain=v1","--branch"])
branch_line = ""
dirty = []
if status_p.returncode == 0:
    for line in status_p.stdout.splitlines():
        if line.startswith("##"):
            branch_line = line[3:]
        elif line.strip():
            dirty.append(line)
diff_stat_p = sh(["git","diff","--stat","--no-color"])
diff_cached_stat_p = sh(["git","diff","--cached","--stat","--no-color"])
diff_name_p = sh(["git","diff","--name-only"])
diff_cached_name_p = sh(["git","diff","--cached","--name-only"])
untracked_p = sh(["git","ls-files","--others","--exclude-standard"])

log_args = ["git","log","--pretty=format:%H%x00%s%x00%b%x00%an%x00%ae%x00%aI%x00%D%x1e"]
if branch: log_args.append(branch)
if since: log_args.append(f"--since={since}")
if limit > 0: log_args.extend(["-n", str(limit)])
else: log_args.extend(["-n","50"])
log_p = sh(log_args)
commits = []
if log_p.returncode == 0:
    for block in log_p.stdout.split("\x1e"):
        block = block.strip("\n")
        if not block.strip(): continue
        parts = block.split("\x00")
        if len(parts) < 7: continue
        h, subj, body, an, ae, ai, dec = parts[:7]
        h = h.strip()
        msg = subj + "\n\n" + body
        trello, closes = parse_trailers(msg)
        refs = [r.strip() for r in body.splitlines() if re.match(r'^\s*Refs\s*:', r, re.I)]
        commits.append({
            "hash": h, "short": h[:7], "subject": subj.strip(), "body": body.strip(),
            "author": an, "email": ae, "date": ai, "decorations": dec.strip(),
            "trello": trello, "closes": closes, "refs": refs
        })

by_card = {}
for c in commits:
    for url in c["trello"]:
        m = re.search(r"/c/([A-Za-z0-9]+)", url)
        if not m: continue
        k = m.group(1)
        if k not in by_card:
            by_card[k] = {"url": url, "last_commit": c["short"], "last_subject": c["subject"], "last_date": c["date"], "closes": url in c["closes"]}

out = {
    "root": root,
    "branch": branch_line,
    "dirty": {
        "porcelain": dirty,
        "has_dirty": len(dirty) > 0,
        "diff_stat": diff_stat_p.stdout.strip() if diff_stat_p.returncode==0 else "",
        "diff_cached_stat": diff_cached_stat_p.stdout.strip() if diff_cached_stat_p.returncode==0 else "",
        "diff_files": [l for l in diff_name_p.stdout.splitlines() if l.strip()] if diff_name_p.returncode==0 else [],
        "cached_files": [l for l in diff_cached_name_p.stdout.splitlines() if l.strip()] if diff_cached_name_p.returncode==0 else [],
        "untracked": [l for l in untracked_p.stdout.splitlines() if l.strip()] if untracked_p.returncode==0 else [],
    },
    "log": {"limit": limit, "since": since or None, "branch": branch or None, "count": len(commits), "commits": commits},
    "by_card": by_card,
}
print(json.dumps(out, ensure_ascii=False))
PY
)
echo "$JSON_OUT"
if [[ $JSON_ONLY -eq 0 ]]; then
  python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print(f"hint: branch={j.get(\"branch\",\"\")} dirty={j[\"dirty\"][\"has_dirty\"]} log={j[\"log\"][\"count\"]} cards={len(j.get(\"by_card\",{}))}", file=sys.stderr)' "$JSON_OUT" 2>/dev/null || true
fi
