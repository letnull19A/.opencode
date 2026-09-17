#!/usr/bin/env bash
# workflows.sh — сводка по GitHub Actions с градацией подробности для ИИ-агента.
# Только чтение (gh / API), без мутаций. stdout — только JSON, stderr — human summary.
#
# Использование (из корня репо):
#   bash .opencode/scripts/ci/workflows.sh status [--branch <name>] [--workflow <file>] [--limit <n>] [--json]
#   bash .opencode/scripts/ci/workflows.sh logs --run <id> [--failed-only] [--json]
#   bash .opencode/scripts/ci/workflows.sh status --branch dev --limit 5 --json
#   bash .opencode/scripts/ci/workflows.sh status --workflow test.yml --json
#
# Режимы подробности:
#   status              — кратко: какие ранны, какие джобы/степы упали (без логов) — для "какой шаг упал"
#   logs --run <id>     — детально: логи упавших джобов/степов (gh run view --log) — для "дай логи"
#   --json              — только JSON на stdout (иначе JSON + summary на stderr)
#
# Требует: gh CLI (auth) или GITHUB_TOKEN env для API fallback, git, python3.

set -euo pipefail

BRANCH=""; WORKFLOW=""; LIMIT=5; RUN_ID=""; FAILED_ONLY=0; JSON_ONLY=0
CMD=""

usage() {
  echo "Usage:"
  echo "  workflows.sh status [--branch <name>] [--workflow <file>] [--limit <n>] [--json]"
  echo "  workflows.sh logs --run <id> [--failed-only] [--json]"
}

if [[ $# -eq 0 ]]; then usage >&2; exit 1; fi
CMD="$1"; shift
case "$CMD" in status|logs) ;; *) echo "workflows: неизвестная команда '$CMD'" >&2; usage >&2; exit 1 ;; esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH="${2:?--branch требует имя ветки}"; shift 2 ;;
    --workflow) WORKFLOW="${2:?--workflow требует файл}"; shift 2 ;;
    --limit) LIMIT="${2:?--limit требует число}"; shift 2 ;;
    --run) RUN_ID="${2:?--run требует id}"; shift 2 ;;
    --failed-only) FAILED_ONLY=1; shift ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "workflows: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

[[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "workflows: --limit только число" >&2; exit 1; }

# git root и repo slug
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo '{"error":"not_git_repo","hint":"запусти из git-репозитория"}'
  exit 1
fi
ROOT="$(git rev-parse --show-toplevel)"
REMOTE_URL="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
# owner/repo из remote
REPO_SLUG="$(printf '%s' "$REMOTE_URL" | sed -E -e 's#^[A-Za-z0-9+.-]+@[^:]+:##' -e 's#^[a-z]+://[^/]+/##' -e 's#\.git$##' | tr -d '\n')"
if [[ -z "$REPO_SLUG" || "$REPO_SLUG" != */* ]]; then
  REPO_SLUG="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]([^/]+/[^/]+).*#\1#' | cut -d'/' -f1-2 | tr -d '\n' || true)"
fi

need_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo '{"error":"no_gh","hint":"нужен gh CLI: https://cli.github.com/ — или задай GITHUB_TOKEN для API fallback"}'
    exit 1
  fi
}

# ---------- status ----------
do_status() {
  need_gh
  local gh_args=(run list --json databaseId,workflowName,headBranch,event,status,conclusion,createdAt,url,workflowDatabaseId --limit "$LIMIT")
  if [[ -n "$BRANCH" ]]; then gh_args+=(--branch "$BRANCH"); fi
  if [[ -n "$WORKFLOW" ]]; then gh_args+=(--workflow "$WORKFLOW"); fi

  local runs_json
  if ! runs_json="$(gh "${gh_args[@]}" 2>/dev/null)"; then
    # fallback: без фильтра workflow (gh иногда не находит по имени файла)
    runs_json="$(gh run list --json databaseId,workflowName,headBranch,event,status,conclusion,createdAt,url --limit "$LIMIT" ${BRANCH:+--branch "$BRANCH"} 2>/dev/null || echo "[]")"
    if [[ -n "$WORKFLOW" ]]; then
      runs_json="$(printf '%s' "$runs_json" | python3 -c 'import json,sys; wf=sys.argv[1]; data=json.load(sys.stdin); print(json.dumps([r for r in data if wf in r.get("workflowName","") or wf in str(r.get("workflowDatabaseId",""))]))' "$WORKFLOW")"
    fi
  fi

  # обогащаем failed степами через gh run view --json jobs
  python3 - "$runs_json" "$BRANCH" "$WORKFLOW" << 'PY'
import json, sys, subprocess, os
runs_json, branch, workflow = sys.argv[1], sys.argv[2], sys.argv[3]
runs=json.loads(runs_json) if runs_json.strip() else []
# если runs пустой — пробуем без фильтров (gh иногда требует --repo)
if not runs:
    try:
        import subprocess as sp
        out=sp.run(["gh","run","list","--json","databaseId,workflowName,headBranch,event,status,conclusion,createdAt,url","--limit","5"], capture_output=True, text=True, timeout=10)
        if out.returncode==0 and out.stdout.strip():
            runs=json.loads(out.stdout)
    except: pass

enriched=[]
for r in runs:
    rid=r.get("databaseId")
    entry={
        "id": rid,
        "name": r.get("workflowName"),
        "branch": r.get("headBranch"),
        "event": r.get("event"),
        "status": r.get("status"),
        "conclusion": r.get("conclusion"),
        "createdAt": r.get("createdAt"),
        "url": r.get("url"),
        "jobs": [],
        "failedSteps": []
    }
    # тянем джобы только для completed с failure/cancelled (экономим запросы)
    if r.get("status")=="completed" and r.get("conclusion") in ("failure","cancelled","timed_out"):
        try:
            out=subprocess.run(["gh","run","view",str(rid),"--json","jobs"], capture_output=True, text=True, timeout=15)
            if out.returncode==0:
                j=json.loads(out.stdout)
                jobs=j.get("jobs",[])
                for job in jobs:
                    jc=job.get("conclusion")
                    if jc not in ("success","skipped","neutral"):
                        steps=job.get("steps",[])
                        failed=[{"name": s.get("name"), "conclusion": s.get("conclusion")} for s in steps if s.get("conclusion")=="failure"]
                        entry["jobs"].append({"id": job.get("databaseId"), "name": job.get("name"), "conclusion": jc, "failedSteps": failed})
                        entry["failedSteps"].extend(failed)
        except: pass
    enriched.append(entry)

# фильтр по branch/workflow уже на уровне gh, но на всякий — ещё раз
if branch:
    enriched=[e for e in enriched if e["branch"]==branch]
if workflow:
    enriched=[e for e in enriched if workflow in (e["name"] or "")]

failed=[e for e in enriched if e["conclusion"] in ("failure","cancelled","timed_out")]
summary=f"{len(enriched)} runs"
if failed:
    summary+=f", {len(failed)} failed"
    # кратко: какой workflow/степ упал
    for f in failed[:3]:
        steps=", ".join(s["name"] for s in f["failedSteps"][:2]) if f["failedSteps"] else f["jobs"][0]["name"] if f["jobs"] else "unknown step"
        summary+=f" | {f['name']}#{f['id']}: {steps}"
else:
    summary+=", all passed" if enriched else ", no runs"

out={"repo": os.environ.get("REPO_SLUG",""), "branch": branch or None, "workflow": workflow or None, "runs": enriched, "summary": summary}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
  rm -f "$tmp_info" "$tmp_log"
}

# ---------- logs ----------
do_logs() {
  [[ -n "$RUN_ID" ]] || { echo "workflows: укажи --run <id>" >&2; usage >&2; exit 1; }
  need_gh
  # проверяем что ран существует и берём его инфо
  local info
  info="$(gh run view "$RUN_ID" --json databaseId,workflowName,headBranch,conclusion,url,jobs 2>/dev/null || echo "{}")"

  # логи: gh run view --log (zip textual) — берём только упавшие джобы если --failed-only
  local log_text=""
  if [[ $FAILED_ONLY -eq 1 ]]; then
    # gh run view --log возвращает все логи, но мы отфильтруем по failed jobs через json
    # берём логи и режем по failed job names
    log_text="$(gh run view "$RUN_ID" --log 2>&1 | head -n 4000 || true)"
    # если gh не дал логов (нужен --repo), пробуем с --repo
    if [[ -z "$log_text" || "$log_text" == *"not found"* ]]; then
      log_text="$(gh run view "$RUN_ID" --log --repo "$REPO_SLUG" 2>&1 | head -n 4000 || true)"
    fi
  else
    log_text="$(gh run view "$RUN_ID" --log 2>&1 | head -n 4000 || true)"
    if [[ -z "$log_text" || "$log_text" == *"not found"* ]]; then
      log_text="$(gh run view "$RUN_ID" --log --repo "$REPO_SLUG" 2>&1 | head -n 4000 || true)"
    fi
  fi
  # если gh log пустой — пробуем API fallback (curl)
  if [[ -z "$log_text" || "$log_text" == *"API rate limit"* ]]; then
    log_text="(логи недоступны — проверь gh auth / GITHUB_TOKEN, либо смотри url)"
  fi

  local tmp_info tmp_log
  tmp_info="$(mktemp)"
  tmp_log="$(mktemp)"
  printf '%s' "$info" > "$tmp_info"
  printf '%s' "$log_text" > "$tmp_log"
  python3 - "$tmp_info" "$tmp_log" "$RUN_ID" << 'PY'
import json, sys
info_path, log_path, rid = sys.argv[1], sys.argv[2], sys.argv[3]
info_json = open(info_path, encoding='utf-8').read()
log_text = open(log_path, encoding='utf-8').read()
try:
    info=json.loads(info_json) if info_json.strip().startswith("{") else {}
except: info={}
# jobs из info
jobs=info.get("jobs",[])
failed_jobs=[j for j in jobs if j.get("conclusion") not in ("success","skipped","neutral")]
out={
    "run": {"id": info.get("databaseId") or rid, "name": info.get("workflowName"), "branch": info.get("headBranch"), "conclusion": info.get("conclusion"), "url": info.get("url")},
    "failedJobs": [{"id": j.get("databaseId"), "name": j.get("name"), "conclusion": j.get("conclusion"), "failedSteps": [s for s in j.get("steps",[]) if s.get("conclusion")=="failure"]} for j in failed_jobs],
    "logExcerpt": log_text[:8000],
    "hint": "logExcerpt — первые 4000 строк лога (gh run view --log). Для полного — gh run view <id> --log > /tmp/log.txt"
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
  rm -f "$tmp_info" "$tmp_log"
}

case "$CMD" in
  status)
    JSON_OUT="$(do_status)"
    echo "$JSON_OUT"
    if [[ $JSON_ONLY -eq 0 ]]; then
      python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print(j["summary"], file=sys.stderr)' "$JSON_OUT" 2>/dev/null || true
    fi
    ;;
  logs)
    JSON_OUT="$(do_logs)"
    echo "$JSON_OUT"
    if [[ $JSON_ONLY -eq 0 ]]; then
      python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print(f"run {j[\"run\"].get(\"id\")} {j[\"run\"].get(\"conclusion\")} — failed jobs: {len(j[\"failedJobs\"])}", file=sys.stderr); 
if j["failedJobs"]:
    for fj in j["failedJobs"]:
        print(f"  job {fj[\"name\"]}: " + ", ".join(s["name"] for s in fj["failedSteps"][:3]), file=sys.stderr)
' "$JSON_OUT" 2>/dev/null || true
    fi
    ;;
esac
