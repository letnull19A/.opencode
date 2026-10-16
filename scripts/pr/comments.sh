#!/usr/bin/env bash
# comments.sh — read-only чтение замечаний ревьюеров PR/MR.
# Ничего не создаёт, на ревью не отвечает — только показывает, что нужно
# доработать. Используется в паре со status-pr.sh: если REVIEWS=changes_requested
# (LIFECYCLE: CHANGES_REQUESTED) — этот скрипт даёт текст замечаний для
# возврата задачи исполнителю. PR принимает только человек, агент не мержит.
#
# Контракт вывода (текстовый режим): блоки
#   --- @author [THREAD: UNRESOLVED] path:line ---
#   <текст>
#   --- @author [REVIEW: CHANGES_REQUESTED] ---
#   <текст>
# Нерешённые треды — первыми (их чинить обязательно), затем ревью, затем
# общие комментарии. Замечаний нет — строка `(no review comments)`, exit 0.
# --json — тот же набор: {"pr": N, "count": M,
#   "items": [{author, kind: thread|review|comment, state, body, path}]}.
#
# Коды выхода: 0 — прочитано (даже если замечаний нет); 1 — фатальная ошибка
# (не git-репозиторий, нет провайдера/CLI, PR для ветки не найден).
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/pr/comments.sh [--branch <name>] [--json]

set -euo pipefail

BRANCH=""
AS_JSON=0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$DIR/../issue-writer/detect-provider.sh"

usage() {
  echo "Usage: comments.sh [--branch <name>] [--json]"
  echo "  Показывает замечания ревьюеров PR/MR ветки (read-only)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="${2:?--branch требует имя ветки}"
      shift 2
      ;;
    --json)
      AS_JSON=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "comments: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "comments: не git-репозиторий (запусти из корня проекта)" >&2; exit 1; }

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git branch --show-current || true)"
  [[ -n "$BRANCH" ]] || { echo "comments: detached HEAD — укажи --branch явно" >&2; exit 1; }
fi

PROVIDER="$("$DETECT" 2>/dev/null)" || {
  echo "comments: не смог определить провайдера (см. issue_provider в AGENTS.md)" >&2
  exit 1
}

export AS_JSON
export BRANCH

render_python='
import json, os, sys
d = json.load(sys.stdin)
items = d.get("items", [])
pr = d.get("pr", "")
if os.environ.get("AS_JSON") == "1":
    print(json.dumps({"pr": pr, "count": len(items), "items": items}, ensure_ascii=False, indent=2))
    sys.exit(0)
if not items:
    print("(no review comments)")
    sys.exit(0)
for it in items:
    head = "--- @%s [%s%s]%s ---" % (
        it.get("author", "?"),
        it.get("kind", "?").upper(),
        (": " + it["state"] if it.get("state") else ""),
        (" " + it["path"] if it.get("path") else ""),
    )
    print(head)
    print(it.get("body", ""))
    print()
'

case "$PROVIDER" in
  github)
    command -v gh >/dev/null || { echo "comments: нужен gh: https://cli.github.com" >&2; exit 1; }
    DATA="$(gh pr view "$BRANCH" --json number,reviews,comments 2>/dev/null || true)"
    if [[ -z "$DATA" || "$DATA" == "null" ]]; then
      echo "comments: PR для ветки '$BRANCH' не найден" >&2; exit 1
    fi
    # Инлайн-треды (path:line + resolved) — через GraphQL: в gh pr view их нет.
    NWO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    THREADS=""
    if [[ -n "$NWO" ]]; then
      OWNER="${NWO%%/*}"; REPO="${NWO##*/}"
      PRNUM="$(echo "$DATA" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("number",""))' 2>/dev/null || true)"
      if [[ -n "$PRNUM" ]]; then
        THREADS="$(gh api graphql -f owner="$OWNER" -f repo="$REPO" -F number="$PRNUM" \
          -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:50){nodes{isResolved path line comments(first:20){nodes{author{login} body}}}}}}}' \
          2>/dev/null || true)"
      fi
    fi
    export THREADS
    echo "$DATA" | python3 -c '
import json, os, sys
d = json.load(sys.stdin)
items = []
try:
    tdata = json.loads(os.environ.get("THREADS") or "{}")
    nodes = ((tdata.get("data") or {}).get("repository") or {}).get("pullRequest", {})
    nodes = (nodes.get("reviewThreads") or {}).get("nodes", [])
except Exception:
    nodes = []
for t in nodes:
    cs = ((t.get("comments") or {}).get("nodes")) or []
    bodies = [c.get("body", "") for c in cs]
    body = "\n---\n".join(b for b in bodies if b.strip())
    if not body.strip():
        continue
    author = ((cs[0].get("author") or {}) or {}).get("login", "?")
    p = t.get("path") or ""
    ln = t.get("line") or ""
    loc = ("%s:%s" % (p, ln)) if p else ""
    items.append({"author": author,
                  "kind": "thread",
                  "state": "RESOLVED" if t.get("isResolved") else "UNRESOLVED",
                  "body": body, "path": loc})
for r in (d.get("reviews") or []):
    if not (r.get("body") or "").strip():
        continue
    items.append({"author": (r.get("author") or {}).get("login", "?"),
                  "kind": "review", "state": r.get("state", ""),
                  "body": r.get("body", ""), "path": ""})
for c in (d.get("comments") or []):
    if not (c.get("body") or "").strip():
        continue
    items.append({"author": (c.get("author") or {}).get("login", "?"),
                  "kind": "comment", "state": "",
                  "body": c.get("body", ""), "path": ""})
# нерешённые треды — первыми
items.sort(key=lambda i: 0 if (i["kind"] == "thread" and i["state"] == "UNRESOLVED") else 1)
print(json.dumps({"pr": d.get("number", ""), "items": items}))
' | python3 -c "$render_python"
    ;;

  gitlab)
    command -v glab >/dev/null || { echo "comments: нужен glab: https://gitlab.com/gitlab-org/cli" >&2; exit 1; }
    LIST="$(glab mr list --source-branch "$BRANCH" --output json 2>/dev/null || true)"
    export PR_ID="$(echo "$LIST" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0].get("iid","") if isinstance(d,list) and d else "")' 2>/dev/null || true)"
    if [[ -z "${PR_ID:-}" ]]; then
      echo "comments: MR для ветки '$BRANCH' не найден" >&2; exit 1
    fi
    # Заметки через api; системные (смена diff) отбрасываем.
    NOTES="$(glab api "merge_requests/$PR_ID/notes?per_page=100" --paginate 2>/dev/null || glab api "merge_requests/$PR_ID/notes" 2>/dev/null || true)"
    if [[ -z "$NOTES" ]]; then
      echo "comments: не смог прочитать заметки MR !$PR_ID (прочитай их в UI)" >&2; exit 1
    fi
    echo "$NOTES" | python3 -c '
import json, os, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    d = []
if isinstance(d, dict):
    d = [d]
items = []
for n in (d if isinstance(d, list) else []):
    if n.get("system"):
        continue
    body = (n.get("body") or "").strip()
    if not body:
        continue
    items.append({"author": (n.get("author") or {}).get("username", "?"),
                  "kind": "comment", "state": "",
                  "body": body, "path": ""})
print(json.dumps({"pr": os.environ.get("PR_ID", ""), "items": items}))
' | python3 -c "$render_python"
    ;;

  gitea)
    echo "comments: gitea/tea не отдаёт замечания стабильно — прочитай их в UI" >&2
    exit 1
    ;;

  bitbucket)
    : "${BITBUCKET_WORKSPACE:?нужен env BITBUCKET_WORKSPACE}" "${BITBUCKET_REPO_SLUG:?нужен env BITBUCKET_REPO_SLUG}" "${BITBUCKET_USERNAME:?нужен env BITBUCKET_USERNAME}" "${BITBUCKET_APP_PASSWORD:?нужен env BITBUCKET_APP_PASSWORD}"
    RESP="$(curl -sf -u "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" \
      "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests?q=source.branch.name+%3D+%22${BRANCH}%22" 2>/dev/null || true)"
    export PR_ID="$(echo "$RESP" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); v=d.get("values",[]); print(v[0].get("id","") if v else "")' 2>/dev/null || true)"
    if [[ -z "${PR_ID:-}" ]]; then
      echo "comments: PR для ветки '$BRANCH' не найден" >&2; exit 1
    fi
    COMMS="$(curl -sf -u "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" \
      "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests/${PR_ID}/comments?pagelen=100" 2>/dev/null || true)"
    echo "$COMMS" | python3 -c '
import json, os, sys
d = json.loads(sys.stdin.read() or "{}")
items = []
def walk(cs):
    for c in (cs or []):
        body = ((c.get("content") or {}).get("raw") or "").strip()
        if body and not c.get("deleted", False):
            inline = c.get("inline") or {}
            loc = ""
            if inline.get("path"):
                loc = "%s:%s" % (inline.get("path"), inline.get("to") or inline.get("from") or "")
            items.append({"author": ((c.get("user") or {}).get("nickname") or "?"),
                          "kind": "comment", "state": "",
                          "body": body, "path": loc})
        walk(c.get("children"))
walk(d.get("values", []) if isinstance(d, dict) else [])
print(json.dumps({"pr": os.environ.get("PR_ID", ""), "items": items}))
' | python3 -c "$render_python"
    ;;

  *)
    echo "comments: неизвестный provider '$PROVIDER'" >&2
    exit 1
    ;;
esac
