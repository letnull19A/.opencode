#!/usr/bin/env bash
# list-prs.sh — список PR/MR с живыми статусами. Read-only: только CLI/API,
# ничего не создаёт и не меняет. Никакого LLM.
#
#   bash .opencode/scripts/pr/list-prs.sh [--filter open|closed|merged|all]
#       [--status <lifecycle>] [--author me] [--limit N] [--json]
#
# Контракт вывода: `--json` — массив объектов {number, url, title, head, base,
# state, draft, conflicts, checks, reviews, lifecycle} (у каждого PR полный
# набор, unknown честно остаётся unknown). Без `--json` — таблица + строки
# `PR: #<n> <url> | lifecycle=<X>`.
#
# --status <lifecycle> — фильтр по стадии из status-pr.sh (NO_PR не бывает:
# это «PR нет», в списке строк не будет): DRAFT, CONFLICTS, CHECKS_FAILING,
# CHECKS_PENDING, CHANGES_REQUESTED, APPROVED, AWAITING_REVIEW, MERGED, CLOSED.
# Фильтр применяется ПОСЛЕ вычисления lifecycle (same derivation as status-pr.sh).
#
# Коды: 0 — отработал (пусто = «нет подходящих», не ошибка); 1 — usage/git/provider/CLI.
# CLI-зависимости как у create-pr: gh / glab / tea / REST bitbucket.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$DIR/../issue-writer/detect-provider.sh"

FILTER="open"
STATUS_FILTER=""
AUTHOR=""
LIMIT=50
JSON=0

usage() {
  echo "Usage: list-prs.sh [--filter open|closed|merged|all] [--status <lifecycle>]"
  echo "         [--author me] [--limit N] [--json]"
  echo "  Список PR/MR с живыми статусами (read-only)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter) FILTER="${2:?--filter требует open|closed|merged|all}"; shift 2;;
    --status) STATUS_FILTER="${2:?--status требует lifecycle}"; shift 2;;
    --author) AUTHOR="${2:?--author требует значение}"; shift 2;;
    --limit) LIMIT="${2:?--limit требует число}"; shift 2;;
    --json) JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "list-prs: неизвестный аргумент '$1'" >&2; usage >&2; exit 1;;
  esac
done

case "$FILTER" in
  open|closed|merged|all) ;;
  *) echo "list-prs: --filter только open|closed|merged|all" >&2; exit 1;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "list-prs: не git-репозиторий" >&2; exit 1; }

PROVIDER="$("$DETECT" 2>/dev/null)" || {
  echo "list-prs: не смог определить провайдера (см. issue_provider в AGENTS.md)" >&2
  exit 1
}

# Сырой список PR в JSON: [{number,url,title,head,base,state,draft}]
RAW=""
case "$PROVIDER" in
  github)
    command -v gh >/dev/null || { echo "list-prs: нужен gh: https://cli.github.com" >&2; exit 1; }
    ARGS=(pr list --limit "$LIMIT" --json number,url,title,headRefName,baseRefName,state,isDraft)
    case "$FILTER" in
      open|closed|merged) ARGS+=(--state "$FILTER");;
    esac
    [[ "$AUTHOR" == "me" ]] && ARGS+=(--author "@me")
    RAW="$(gh "${ARGS[@]}" 2>/dev/null || echo "[]")"
    # checks + reviews по каждому PR (best effort, gh сам умеет — один вызов на PR).
    ;;
  gitlab)
    command -v glab >/dev/null || { echo "list-prs: нужен glab: https://gitlab.com/gitlab-org/cli" >&2; exit 1; }
    RAW="$(glab mr list --output json --per-page "$LIMIT" 2>/dev/null || echo "[]")"
    ;;
  gitea)
    command -v tea >/dev/null || { echo "list-prs: нужен tea: https://gitea.com/gitea/tea" >&2; exit 1; }
    RAW="$(tea pr ls --output json --limit "$LIMIT" 2>/dev/null || echo "[]")"
    ;;
  bitbucket)
    : "${BITBUCKET_WORKSPACE:?}" "${BITBUCKET_REPO_SLUG:?}" "${BITBUCKET_USERNAME:?}" "${BITBUCKET_APP_PASSWORD:?}"
    RAW="$(curl -s -u "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" \
      "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests?pagelen=${LIMIT}" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([{ "number":v.get("id"), "url":(v.get("links") or {}).get("html",{}).get("href",""), "title":v.get("title",""), "head":((v.get("source") or {}).get("branch") or {}).get("name",""), "base":((v.get("destination") or {}).get("branch") or {}).get("name",""), "state":v.get("state",""), "draft":False } for v in d.get("values",[])]))' 2>/dev/null || echo "[]")"
    ;;
  *)
    echo "list-prs: неизвестный provider '$PROVIDER'" >&2
    exit 1
    ;;
esac

echo "list-prs: provider=$PROVIDER" >&2

# Per-PR добираем checks/reviews/conflicts (best effort). gh жёстко трактует
# список номеров как имя ветки, поэтому по одному вызову на PR.
if [[ "$PROVIDER" == "github" && "$RAW" != "[]" ]]; then
  ENRICHED="[]"
  while IFS= read -r num; do
    M="$(gh pr view "$num" --json number,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup 2>/dev/null || true)"
    [[ -z "$M" ]] && continue
    ENRICHED="$(python3 - "$ENRICHED" "$M" <<'PY'
import json, sys
items = json.loads(sys.argv[1])
m = json.loads(sys.argv[2])
roll = m.get("statusCheckRollup") or []
fails = [c.get("name","?") for c in roll if c.get("conclusion") in ("FAILURE","TIMED_OUT","ACTION_REQUIRED","CANCELLED")]
pend = [c.get("name","?") for c in roll if c.get("status") in ("QUEUED","IN_PROGRESS","PENDING","REQUESTED","WAITING")]
ok = sum(1 for c in roll if c.get("conclusion") == "SUCCESS")
items.append({
  "number": m.get("number"),
  "conflicts": ("yes" if (m.get("mergeable")=="CONFLICTING" or m.get("mergeStateStatus")=="DIRTY")
                else "no" if m.get("mergeable")=="MERGEABLE" else "unknown"),
  "checks": "failing" if fails else "pending" if pend else "passing" if roll else "none",
  "reviews": {"APPROVED":"approved","CHANGES_REQUESTED":"changes_requested","REVIEW_REQUIRED":"awaiting"}.get(m.get("reviewDecision") or "", "none"),
})
print(json.dumps(items))
PY
)"
  done < <(echo "$RAW" | python3 -c 'import json,sys; [print(p["number"]) for p in json.load(sys.stdin)]' 2>/dev/null || true)
  RAW="$(python3 - "$RAW" "$ENRICHED" <<'PY'
import json, sys
prs = json.loads(sys.argv[1]); meta = {m["number"]: m for m in json.loads(sys.argv[2])}
for p in prs:
    m = meta.get(p["number"])
    if not m:
        continue
    p["conflicts"] = m["conflicts"]
    p["checks"] = m["checks"]
    p["reviews"] = m["reviews"]
print(json.dumps(prs))
PY
)"
fi

# Нормализация + lifecycle (та же приоритетная лестница, что в status-pr.sh).
OUT="$(python3 - "$RAW" "$FILTER" "$STATUS_FILTER" <<'PY'
import json, sys
raw, filt, status_filt = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    prs = json.loads(raw)
except Exception:
    prs = []
if isinstance(prs, dict):
    prs = [prs]

def normalize(p):
    if "iid" in p and "number" not in p:   # gitlab
        p["number"] = p.get("iid")
    if "headRefName" not in p and isinstance(p.get("head_ref"), str):
        p["headRefName"] = p["head_ref"]
    if "baseRefName" not in p and isinstance(p.get("target_branch"), str):
        p["baseRefName"] = p["target_branch"]
    if "title" not in p:
        p["title"] = p.get("name") or p.get("head", {}).get("ref", "") if isinstance(p.get("head"), dict) else p.get("name", "")
    if "state" not in p and isinstance(p.get("status"), str):
        p["state"] = p["status"].upper()
    if "isDraft" in p:
        p["draft"] = p["isDraft"]
    p.setdefault("draft", False)
    p.setdefault("conflicts", "unknown")
    p.setdefault("checks", "unknown")
    p.setdefault("reviews", "unknown")
    p.setdefault("url", "")
    return p

def lifecycle(p):
    state = (p.get("state") or "").upper()
    if "MERGED" in state: return "MERGED"
    if "CLOSED" in state or "DECLINED" in state: return "CLOSED"
    if p["draft"]: return "DRAFT"
    if p["conflicts"] == "yes": return "CONFLICTS"
    if p["checks"] == "failing": return "CHECKS_FAILING"
    if p["checks"] == "pending": return "CHECKS_PENDING"
    if p["reviews"] == "changes_requested": return "CHANGES_REQUESTED"
    if p["reviews"] == "approved": return "APPROVED"
    return "AWAITING_REVIEW"

out = []
for p in map(normalize, prs):
    lc = lifecycle(p)
    state = (p.get("state") or "").upper()
    openish = not ("MERGED" in state or "CLOSED" in state or "DECLINED" in state or "SUPPRESSED" in state)
    if filt == "open" and not openish: continue
    if filt == "closed" and openish: continue
    if filt == "merged" and "MERGED" not in state: continue
    if status_filt and lc != status_filt: continue
    out.append({
        "number": p.get("number") or p.get("id") or "",
        "url": p.get("url") or p.get("web_url") or "",
        "title": p.get("title", ""),
        "head": p.get("headRefName", ""),
        "base": p.get("baseRefName", ""),
        "state": state,
        "draft": bool(p["draft"]),
        "conflicts": p["conflicts"],
        "checks": p["checks"],
        "reviews": p["reviews"],
        "lifecycle": lc,
    })
print(json.dumps(out))
PY
)"

if [[ "$JSON" -eq 1 ]]; then
  echo "$OUT"
  exit 0
fi

COUNT="$(echo "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
if [[ "$COUNT" == "0" ]]; then
  echo "list-prs: нет PR по фильтру (filter=$FILTER status=${STATUS_FILTER:-any})"
  exit 0
fi

printf "%-6s %-18s %-28s %-10s %s\n" "NUM" "LIFECYCLE" "HEAD" "CHECKS" "TITLE"
echo "$OUT" | python3 -c '
import json, sys
for p in json.load(sys.stdin):
    title = p["title"][:44] + ("…" if len(p["title"]) > 44 else "")
    head = (p["head"] or "-")[:26]
    print("%-6s %-18s %-28s %-10s %s" % ("#"+str(p["number"]), p["lifecycle"], head, p["checks"], title))
'
echo "---"
echo "$OUT" | python3 -c '
import json, sys
for p in json.load(sys.stdin):
    print("PR: #%s %s | lifecycle=%s" % (p["number"], p["url"], p["lifecycle"]))
'