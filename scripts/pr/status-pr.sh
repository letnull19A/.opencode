#!/usr/bin/env bash
# status-pr.sh — ЕДИНСТВЕННЫЙ источник правды о состоянии PR/MR.
# Read-only: ничего не создаёт, только читает через готовые CLI/API.
# Агент обязан вызывать его ПЕРЕД любым ответом о PR (конфликты, checks,
# reviews, готов ли к мержу) и отвечать СТРОГО по его выводу — не по памяти.
#
# Контракт вывода (полный режим): строки-ключи, которые агент парсит:
#   PR_URL: <url> | none
#   STATE: OPEN|DRAFT|MERGED|CLOSED|NONE
#   CONFLICTS: yes|no|unknown
#   CHECKS: passing|failing|pending|none|unknown
#   REVIEWS: approved|changes_requested|awaiting|none|unknown
#   LIFECYCLE: <stage>   (NO_PR|DRAFT|CONFLICTS|CHECKS_FAILING|CHECKS_PENDING|
#                         CHANGES_REQUESTED|APPROVED|AWAITING_REVIEW|MERGED|CLOSED)
# Короткий режим (--short): одна строка
#   PR_STATUS: <LIFECYCLE> | conflicts: X | checks: Y | reviews: Z
#
# Правило: CONFLICTS: unknown означает «не знаю», а не «конфликтов нет».
# Утверждать отсутствие конфликтов разрешено только при CONFLICTS: no.
#
# Использование:
#   bash .opencode/scripts/pr/status-pr.sh [--branch <name>] [--short]

set -euo pipefail

BRANCH=""
SHORT=0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$DIR/../issue-writer/detect-provider.sh"
GET_URL="$DIR/get-pr-url.sh"

usage() {
  echo "Usage: status-pr.sh [--branch <name>] [--short]"
  echo "  Показывает живое состояние PR/MR текущей ветки и его lifecycle-стадию."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="${2:?--branch требует имя ветки}"
      shift 2
      ;;
    --short)
      SHORT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "status-pr: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "status-pr: не git-репозиторий" >&2; exit 1; }

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git branch --show-current || true)"
  [[ -n "$BRANCH" ]] || { echo "status-pr: detached HEAD — укажи --branch явно" >&2; exit 1; }
fi

PROVIDER="$("$DETECT" 2>/dev/null)" || {
  echo "status-pr: не смог определить провайдера (см. issue_provider в AGENTS.md)" >&2
  exit 1
}

# Дефолт: PR нет. Дальше провайдер перезапишет то, что смог узнать.
# Неизвестное остаётся unknown — это честный ответ, а не «всё хорошо».
PR_URL="none"
STATE="NONE"
DRAFT="no"
CONFLICTS="unknown"
CHECKS="unknown"
REVIEWS="unknown"
CHECKS_DETAIL=""
EXTRA=""

emit() {
  if [[ "$SHORT" -eq 1 ]]; then
    echo "PR_STATUS: $LIFECYCLE | conflicts: $CONFLICTS | checks: $CHECKS | reviews: $REVIEWS"
  else
    echo "PR_URL: $PR_URL"
    echo "STATE: $STATE"
    echo "CONFLICTS: $CONFLICTS"
    echo "CHECKS: $CHECKS"
    echo "REVIEWS: $REVIEWS"
    echo "LIFECYCLE: $LIFECYCLE"
    if [[ -n "$CHECKS_DETAIL" ]]; then
      echo "--- checks ---"
      echo "$CHECKS_DETAIL"
    fi
    if [[ -n "$EXTRA" ]]; then
      echo "--- details ---"
      echo "$EXTRA"
    fi
  fi
  return 0
}

derive_lifecycle() {
  case "$STATE" in
    NONE)    LIFECYCLE="NO_PR"; return ;;
    MERGED)  LIFECYCLE="MERGED"; return ;;
    CLOSED)  LIFECYCLE="CLOSED"; return ;;
  esac
  if [[ "$DRAFT" == "yes" ]]; then LIFECYCLE="DRAFT"; return; fi
  if [[ "$CONFLICTS" == "yes" ]]; then LIFECYCLE="CONFLICTS"; return; fi
  if [[ "$CHECKS" == "failing" ]]; then LIFECYCLE="CHECKS_FAILING"; return; fi
  if [[ "$CHECKS" == "pending" ]]; then LIFECYCLE="CHECKS_PENDING"; return; fi
  case "$REVIEWS" in
    changes_requested) LIFECYCLE="CHANGES_REQUESTED"; return ;;
    approved)          LIFECYCLE="APPROVED"; return ;;
  esac
  LIFECYCLE="AWAITING_REVIEW"
}

case "$PROVIDER" in
  github)
    command -v gh >/dev/null || { echo "status-pr: нужен gh: https://cli.github.com" >&2; exit 1; }
    CORE="$(gh pr view "$BRANCH" --json url,number,state,isDraft,mergeable,mergeStateStatus,baseRefName,headRefName,additions,deletions,changedFiles 2>/dev/null || true)"
    if [[ -z "$CORE" || "$CORE" == "null" ]]; then
      # PR для ветки нет — это штатный случай, а не ошибка.
      LIFECYCLE="NO_PR"
      emit
      exit 0
    fi
    eval "$(echo "$CORE" | python3 -c '
import json,sys
d = json.load(sys.stdin)
print("PR_URL=" + repr(d.get("url","")))
print("GH_STATE=" + repr(d.get("state","")))
print("GH_DRAFT=" + repr("yes" if d.get("isDraft") else "no"))
print("GH_MERGEABLE=" + repr(d.get("mergeable") or ""))
print("GH_MERGESTATE=" + repr(d.get("mergeStateStatus") or ""))
print("GH_BASE=" + repr(d.get("baseRefName") or ""))
print("GH_HEAD=" + repr(d.get("headRefName") or ""))
print("GH_NUM=" + repr(str(d.get("number",""))))
print("GH_ADD=" + repr(str(d.get("additions","?"))))
print("GH_DEL=" + repr(str(d.get("deletions","?"))))
print("GH_FILES=" + repr(str(d.get("changedFiles","?"))))
')"
    STATE="$GH_STATE"
    DRAFT="$GH_DRAFT"
    EXTRA="number: #$GH_NUM
base: $GH_BASE ← head: $GH_HEAD
diff: +$GH_ADD -$GH_DEL в $GH_FILES файлах"
    # mergeable — прямой ответ про конфликты; mergeStateStatus DIRTY — тоже конфликты.
    if [[ "$GH_MERGEABLE" == "CONFLICTING" || "$GH_MERGESTATE" == "DIRTY" ]]; then
      CONFLICTS="yes"
    elif [[ "$GH_MERGEABLE" == "MERGEABLE" ]]; then
      CONFLICTS="no"
    fi
    if [[ "$GH_MERGESTATE" == "BEHIND" ]]; then
      EXTRA="$EXTRA
note: ветка отстаёт от base (BEHIND) — после мержа base стоит подтянуть"
    fi
    # Checks + reviews — best effort: старый gh может не знать поля, тогда unknown.
    META="$(gh pr view "$BRANCH" --json reviewDecision,statusCheckRollup 2>/dev/null || true)"
    if [[ -n "$META" && "$META" != "null" ]]; then
      eval "$(echo "$META" | python3 -c '
import json,sys
d = json.load(sys.stdin)
print("GH_REV=" + repr(d.get("reviewDecision") or ""))
roll = d.get("statusCheckRollup") or []
fails = [c.get("name","?") for c in roll if c.get("conclusion") in ("FAILURE","TIMED_OUT","ACTION_REQUIRED","CANCELLED")]
pend = [c.get("name","?") for c in roll if c.get("status") in ("QUEUED","IN_PROGRESS","PENDING","REQUESTED","WAITING")]
ok = [c.get("name","?") for c in roll if c.get("conclusion") == "SUCCESS"]
print("GH_FAIL=" + repr(",".join(fails)))
print("GH_PEND=" + repr(",".join(pend)))
print("GH_OK_N=" + repr(str(len(ok))))
print("GH_TOTAL=" + repr(str(len(roll))))
')"
      if [[ -n "$GH_FAIL" ]]; then
        CHECKS="failing"; CHECKS_DETAIL="failed: $GH_FAIL"
      elif [[ -n "$GH_PEND" ]]; then
        CHECKS="pending"; CHECKS_DETAIL="pending: $GH_PEND"
      elif [[ "$GH_TOTAL" != "0" ]]; then
        CHECKS="passing"; CHECKS_DETAIL="$GH_OK_N/$GH_TOTAL checks passed"
      else
        CHECKS="none"
      fi
      case "$GH_REV" in
        APPROVED)          REVIEWS="approved" ;;
        CHANGES_REQUESTED) REVIEWS="changes_requested" ;;
        REVIEW_REQUIRED)   REVIEWS="awaiting" ;;
        "")                REVIEWS="none" ;;
      esac
    fi
    ;;

  gitlab)
    command -v glab >/dev/null || { echo "status-pr: нужен glab: https://gitlab.com/gitlab-org/cli" >&2; exit 1; }
    LIST="$(glab mr list --source-branch "$BRANCH" --output json 2>/dev/null || true)"
    MR="$(echo "$LIST" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[0]) if isinstance(d,list) and d else "")' 2>/dev/null || true)"
    if [[ -z "$MR" ]]; then
      LIFECYCLE="NO_PR"
      emit
      exit 0
    fi
    eval "$(echo "$MR" | python3 -c '
import json,sys
d = json.loads(sys.stdin.read() or "{}")
print("PR_URL=" + repr(d.get("web_url","")))
st = (d.get("state") or "").upper()
print("GL_STATE=" + repr({"OPENED":"OPEN"}.get(st, st)))
print("GL_DRAFT=" + repr("yes" if d.get("draft") or d.get("work_in_progress") else "no"))
print("GL_MERGE=" + repr(d.get("merge_status") or d.get("detailed_merge_status") or ""))
pipe = d.get("pipeline") or {}
print("GL_PIPE=" + repr((pipe.get("status") or "") if isinstance(pipe, dict) else ""))
print("GL_TITLE=" + repr(d.get("title","")))
print("GL_SB=" + repr(d.get("source_branch","")))
print("GL_TB=" + repr(d.get("target_branch","")))
ap = d.get("approved_by") or d.get("approvedBy")
print("GL_APPR=" + repr("yes" if ap else ""))
')"
    STATE="$GL_STATE"
    DRAFT="$GL_DRAFT"
    EXTRA="title: $GL_TITLE
base: $GL_TB ← head: $GL_SB"
    case "$GL_MERGE" in
      *cannot_be_merged*) CONFLICTS="yes" ;;
      *can_be_merged*)    CONFLICTS="no" ;;
    esac
    case "$GL_PIPE" in
      success) CHECKS="passing" ;;
      failed)  CHECKS="failing" ;;
      running|pending|created|preparing|waiting_for_resource|manual) CHECKS="pending" ;;
      canceled|skipped) CHECKS="none" ;;
      "") CHECKS="unknown" ;;
    esac
    [[ -n "$GL_PIPE" && "$GL_PIPE" != "" ]] && CHECKS_DETAIL="pipeline: $GL_PIPE"
    [[ "$GL_APPR" == "yes" ]] && REVIEWS="approved"
    ;;

  gitea)
    command -v tea >/dev/null || { echo "status-pr: нужен tea: https://gitea.com/gitea/tea" >&2; exit 1; }
    # tea не отдаёт conflicts/checks в стабильном формате — честно показываем
    # только факт существования PR, остальное unknown (не «всё хорошо»).
    INFO="$(tea pr list --state all --output json 2>/dev/null || tea pulls list --state all --output json 2>/dev/null || true)"
    FOUND="$(echo "$INFO" | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: d = []
if isinstance(d, dict): d = d.get("data", d.get("pulls", []))
for x in (d if isinstance(d, list) else []):
    head = x.get("head") or x.get("head_branch") or ""
    if head == sys.argv[1] or str(x).find(sys.argv[1]) >= 0:
        print(json.dumps({"url": x.get("html_url",""), "state": (x.get("state","") or "").upper(), "draft": bool(x.get("draft"))}))
        break
' "$BRANCH" 2>/dev/null || true)"
    if [[ -z "$FOUND" ]]; then
      LIFECYCLE="NO_PR"
      emit
      exit 0
    fi
    eval "$(echo "$FOUND" | python3 -c '
import json,sys
d = json.loads(sys.stdin.read() or "{}")
print("PR_URL=" + repr(d.get("url","")))
print("TEA_STATE=" + repr(d.get("state","OPEN")))
print("TEA_DRAFT=" + repr("yes" if d.get("draft") else "no"))
')"
    STATE="$TEA_STATE"
    DRAFT="$TEA_DRAFT"
    EXTRA="note: tea не показывает conflicts/checks стабильно — они unknown по-честному"
    ;;

  bitbucket)
    : "${BITBUCKET_WORKSPACE:?нужен env BITBUCKET_WORKSPACE}" "${BITBUCKET_REPO_SLUG:?нужен env BITBUCKET_REPO_SLUG}" "${BITBUCKET_USERNAME:?нужен env BITBUCKET_USERNAME}" "${BITBUCKET_APP_PASSWORD:?нужен env BITBUCKET_APP_PASSWORD}"
    RESP="$(curl -sf -u "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" \
      "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests?q=source.branch.name+%3D+%22${BRANCH}%22" 2>/dev/null || true)"
    ONE="$(echo "$RESP" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); v=d.get("values",[]); print(json.dumps(v[0]) if v else "")' 2>/dev/null || true)"
    if [[ -z "$ONE" ]]; then
      LIFECYCLE="NO_PR"
      emit
      exit 0
    fi
    eval "$(echo "$ONE" | python3 -c '
import json,sys
d = json.loads(sys.stdin.read() or "{}")
print("PR_URL=" + repr(d.get("links",{}).get("html",{}).get("href","")))
st = (d.get("state") or "").upper()
print("BB_STATE=" + repr({"OPEN":"OPEN","MERGED":"MERGED","DECLINED":"CLOSED"}.get(st, st)))
print("BB_DRAFT=" + repr("yes" if d.get("draft") else "no"))
print("BB_TITLE=" + repr(d.get("title","")))
print("BB_SB=" + repr(d.get("source",{}).get("branch",{}).get("name","")))
print("BB_TB=" + repr(d.get("destination",{}).get("branch",{}).get("name","")))
parts = d.get("participants", []) or []
appr = [p for p in parts if p.get("approved")]
print("BB_APPR=" + repr(str(len(appr))))
print("BB_PART=" + repr(str(len(parts))))
tasks = d.get("task_count")
print("BB_TASKS=" + repr(str(tasks) if tasks is not None else ""))
chash = d.get("source",{}).get("commit",{}).get("hash","")
print("BB_HASH=" + repr(chash))
')"
    STATE="$BB_STATE"
    DRAFT="$BB_DRAFT"
    EXTRA="title: $BB_TITLE
base: $BB_TB ← head: $BB_SB"
    # Конфликты: честный тест через тестовый мерж невозможен без записи —
    # пробуем merge-совместимость read-only: её API не даёт, остаётся unknown,
    # ЗА ИСКЛЮЧЕНИЕМ случаев когда Bitbucket сам пометил PR (поле mergeable скрыто).
    if [[ "$BB_APPR" != "0" && -n "$BB_APPR" ]]; then REVIEWS="approved"; fi
    if [[ -n "$BB_TASKS" && "$BB_TASKS" != "0" && "$BB_TASKS" != "None" ]]; then
      EXTRA="$EXTRA
open tasks: $BB_TASKS"
    fi
    # Build-статусы по source-коммиту — best effort.
    if [[ -n "$BB_HASH" ]]; then
      ST="$(curl -sf -u "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" \
        "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/commit/${BB_HASH}/statuses" 2>/dev/null || true)"
      if [[ -n "$ST" ]]; then
        AGG="$(echo "$ST" | python3 -c '
import json,sys
d = json.loads(sys.stdin.read() or "{}")
vals = d.get("values", []) or []
states = [v.get("state","") for v in vals]
if not states: print("none")
elif any(s in ("FAILED","STOPPED") for s in states): print("failing")
elif any(s == "INPROGRESS" for s in states): print("pending")
elif all(s == "SUCCESSFUL" for s in states): print("passing")
else: print("unknown")
' 2>/dev/null || true)"
        [[ -n "$AGG" ]] && CHECKS="$AGG"
      fi
    fi
    ;;

  *)
    echo "status-pr: неизвестный provider '$PROVIDER'" >&2
    exit 1
    ;;
esac

derive_lifecycle
emit
