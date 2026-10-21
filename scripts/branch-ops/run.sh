#!/usr/bin/env bash
# run.sh — опасные веточные операции только в изолированном worktree, детерминированно, с JSON.
# Для ИИ — stdout только JSON, stderr — human hint (с --json тихо).
# Здесь НЕТ и никогда не будет: merge, push, reset --hard, stash,
# cherry-pick --quit, rebase --abort --continue руками. Конфликт — стоп-отчёт
# exit 2 (как rebase), дальше разбор руками, не самолечение.
#
# Использование (изнутри worktree):
#   bash .opencode/scripts/branch-ops/run.sh fetch [--remote <name>] [--json]
#   bash .opencode/scripts/branch-ops/run.sh preview --ref <R> [--base <B>] [--json]
#   bash .opencode/scripts/branch-ops/run.sh collect --from <R> [--json]
#   bash .opencode/scripts/branch-ops/run.sh collect --continue [--json]
#   bash .opencode/scripts/branch-ops/run.sh collect --abort [--json]
#   bash .opencode/scripts/branch-ops/run.sh sync-base --onto <B> [--json]
#
#   fetch     — только голый git fetch <remote> (без refspec/--force/--prune).
#   preview   — read-only прогноз вливания R в HEAD (merge-base + пересечение файлов, heuristic).
#   collect   — поштучный cherry-pick -x уникальных коммитов R (HEAD..R); конфликт — стоп exit 2.
#   sync-base — делегация scripts/sync/rebase.sh --onto <B> (конфликт — стоп-отчёт, relay hint).
#
# Коды выхода: 0 — ок; 1 — ошибка/гейт (usage, неизвестные флаги, isolated:false,
# грязное дерево, нет ref); 2 — конфликт (cherry-pick/rebase остановился, состояние
# оставлено для разбора, сам скрипт дальше не идёт).

set -euo pipefail

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "branch-ops: нужен '$1' (не найден в PATH)" >&2; exit 1; }; }
need_cmd git
need_cmd python3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CMD=""; REF=""; FROM=""; ONTO=""; BASE=""; REMOTE="origin"; JSON_ONLY=0
DO_CONTINUE=0; DO_ABORT=0

usage() {
  echo "Usage:"
  echo "  branch-ops fetch [--remote <name>] [--json]"
  echo "  branch-ops preview --ref <R> [--base <B>] [--json]"
  echo "  branch-ops collect --from <R> [--json]"
  echo "  branch-ops collect --continue [--json]"
  echo "  branch-ops collect --abort [--json]"
  echo "  branch-ops sync-base --onto <B> [--json]"
}

hint() { if [[ $JSON_ONLY -eq 0 ]]; then echo "$@" >&2; fi; }

if [[ $# -eq 0 ]]; then usage >&2; exit 1; fi
if [[ "$1" == "-h" || "$1" == "--help" ]]; then usage; exit 0; fi
CMD="$1"; shift
case "$CMD" in fetch|preview|collect|sync-base) ;; *) echo "branch-ops: неизвестная команда '$CMD'" >&2; usage >&2; exit 1 ;; esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="${2:?--ref требует значение}"; shift 2 ;;
    --from) FROM="${2:?--from требует значение}"; shift 2 ;;
    --onto) ONTO="${2:?--onto требует имя ветки}"; shift 2 ;;
    --base) BASE="${2:?--base требует значение}"; shift 2 ;;
    --remote) REMOTE="${2:?--remote требует имя remote}"; shift 2 ;;
    --continue) DO_CONTINUE=1; shift ;;
    --abort) DO_ABORT=1; shift ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "branch-ops: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

# ---------- гейт изоляции (первым шагом перед любой мутацией) ----------
gate() {
  local verify_out isolated checks
  verify_out="$(bash "$SCRIPT_DIR/../git-recon/run.sh" verify --json 2>/dev/null || true)"
  isolated="$(echo "$verify_out" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("isolated", False)))' 2>/dev/null || echo "False")"
  if [[ "$isolated" != "True" ]]; then
    checks="$(echo "$verify_out" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("checks", []), ensure_ascii=False))' 2>/dev/null || echo "[]")"
    echo "$checks" | python3 -c 'import json,sys; print(json.dumps({"isolated": False, "checks": json.load(sys.stdin)}, ensure_ascii=False))'
    hint "hint: isolated=false — СТОП, мутаций нет, отчёт родителю (не чинить обходами)"
    exit 1
  fi
}

require_clean() {
  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    echo '{"ok": false, "reason": "dirty-tree"}' | python3 -c 'import json,sys; print(json.dumps({"ok": False, "reason": "dirty-tree", "hint": "сначала /commit, stash запрещён"}, ensure_ascii=False))'
    hint "hint: грязное дерево — сначала /commit, stash запрещён (git-policy)"
    exit 1
  fi
}

# gate_soft: как gate, но при незавершённом cherry-pick (CHERRY_PICK_HEAD есть)
# терпит провал ТОЛЬКО проверки clean — иначе --continue/--abort были бы
# заблокированы ровно тогда, когда нужны (дерево грязно по определению конфликта).
# Остальные проверки (is_worktree/registered) — строгие, как в gate.
gate_soft() {
  local verify_out isolated checks only_clean
  verify_out="$(bash "$SCRIPT_DIR/../git-recon/run.sh" verify --json 2>/dev/null || true)"
  isolated="$(echo "$verify_out" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("isolated", False)))' 2>/dev/null || echo "False")"
  if [[ "$isolated" == "True" ]]; then return 0; fi
  if git rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null 2>&1; then
    only_clean="$(echo "$verify_out" | python3 -c 'import json,sys; c=json.load(sys.stdin).get("checks", []); bad=[x["name"] for x in c if not x.get("ok")]; print(str(bad == ["clean"]))' 2>/dev/null || echo "False")"
    if [[ "$only_clean" == "True" ]]; then
      hint "hint: дерево грязно из-за незавершённого cherry-pick — продолжаю (провален только clean)"
      return 0
    fi
  fi
  checks="$(echo "$verify_out" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("checks", []), ensure_ascii=False))' 2>/dev/null || echo "[]")"
  echo "$checks" | python3 -c 'import json,sys; print(json.dumps({"isolated": False, "checks": json.load(sys.stdin)}, ensure_ascii=False))'
  hint "hint: isolated=false — СТОП, мутаций нет, отчёт родителю (не чинить обходами)"
  exit 1
}

conflict_files_json() {
  git status --porcelain 2>/dev/null | python3 -c 'import sys; print("\n".join(l for l in sys.stdin.read().splitlines() if l.strip()))' || true
}

# ---------- fetch ----------
do_fetch() {
  local out
  out="$(git fetch "$REMOTE" 2>&1 || true)"
  echo "$out" | head -n 10 > /tmp/branch_ops_fetch.txt 2>&1 || true
  python3 - "$REMOTE" << 'PY'
import json, sys
remote = sys.argv[1]
lines = open("/tmp/branch_ops_fetch.txt").read().splitlines()
print(json.dumps({"remote": remote, "ok": True, "output": lines[:10]}, ensure_ascii=False))
PY
  hint "hint: fetch — только чтение remote-состояния, ветки не тронуты"
}

# ---------- preview ----------
do_preview() {
  [[ -n "$REF" ]] || { echo "branch-ops preview: укажи --ref <R>" >&2; usage >&2; exit 1; }
  git rev-parse --verify --quiet "$REF^{commit}" >/dev/null 2>&1 \
    || { echo "branch-ops preview: ref '$REF' не найден" >&2; exit 1; }
  local base="$BASE"
  if [[ -z "$base" ]]; then
    base="$(git merge-base HEAD "$REF" 2>/dev/null || true)"
    [[ -n "$base" ]] || { echo "branch-ops preview: нет общего предка HEAD и '$REF'" >&2; exit 1; }
  else
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 \
      || { echo "branch-ops preview: base '$base' не найден" >&2; exit 1; }
  fi
  # R — предок HEAD: вливать нечего
  if git merge-base --is-ancestor "$REF" HEAD 2>/dev/null; then
    python3 - "$REF" "$base" << 'PY'
import json, sys
print(json.dumps({"ref": sys.argv[1], "base": sys.argv[2], "already_merged": True, "fast_forward": False, "clean": True, "commits": [], "likely_conflicts": [], "heuristic": True}, ensure_ascii=False))
PY
    hint "hint: '$REF' уже внутри HEAD — вливать нечего"
    return
  fi
  # HEAD — предок R: fast-forward
  if git merge-base --is-ancestor HEAD "$REF" 2>/dev/null; then
    git log --reverse --format='%H%x01%h%x01%s' "$base..$REF" > /tmp/branch_ops_commits.txt 2>/dev/null || true
    python3 - "$REF" "$base" << 'PY'
import json, sys
commits = []
for line in open("/tmp/branch_ops_commits.txt").read().splitlines():
    parts = line.split("\x01")
    if len(parts) == 3:
        commits.append({"hash": parts[0], "short": parts[1], "subject": parts[2]})
print(json.dumps({"ref": sys.argv[1], "base": sys.argv[2], "already_merged": False, "fast_forward": True, "clean": True, "commits": commits, "likely_conflicts": [], "heuristic": True}, ensure_ascii=False))
PY
    hint "hint: fast-forward возможен — коммитов выше, конфликтов не ожидается"
    return
  fi
  git log --reverse --format='%H%x01%h%x01%s' "$base..$REF" > /tmp/branch_ops_commits.txt 2>/dev/null || true
  git diff --name-only "$base" HEAD > /tmp/branch_ops_ours.txt 2>/dev/null || true
  git diff --name-only "$base" "$REF" > /tmp/branch_ops_theirs.txt 2>/dev/null || true
  python3 - "$REF" "$base" << 'PY'
import json, sys
commits = []
for line in open("/tmp/branch_ops_commits.txt").read().splitlines():
    parts = line.split("\x01")
    if len(parts) == 3:
        commits.append({"hash": parts[0], "short": parts[1], "subject": parts[2]})
ours = {l.strip() for l in open("/tmp/branch_ops_ours.txt").read().splitlines() if l.strip()}
theirs = {l.strip() for l in open("/tmp/branch_ops_theirs.txt").read().splitlines() if l.strip()}
print(json.dumps({"ref": sys.argv[1], "base": sys.argv[2], "already_merged": False, "fast_forward": False, "clean": True, "commits": commits, "likely_conflicts": sorted(ours & theirs), "heuristic": True}, ensure_ascii=False))
PY
  hint "hint: likely_conflicts — эвристика по пересечению файлов, не гарантия; merge запрещён, вливай через collect"
}

# ---------- collect ----------
report_conflict() {
  local sha="$1" done_json="$2" files
  files="$(conflict_files_json)"
  python3 - "$sha" "$done_json" "$files" << 'PY'
import json, sys
sha, done_raw, files_raw = sys.argv[1:4]
done = json.loads(done_raw) if done_raw else []
files = [l for l in files_raw.splitlines() if l.strip()]
print(json.dumps({"done": done, "conflict": {"sha": sha, "files": files}, "hint": "разреши конфликт, затем collect --continue или collect --abort"}, ensure_ascii=False))
PY
}

pick_one() {
  local sha="$1"
  if git cherry-pick -x "$sha" 2>&1 | tail -n 5 >&2; then
    return 0
  fi
  return 1
}

do_collect_fresh() {
  [[ -n "$FROM" ]] || { echo "branch-ops collect: укажи --from <R>" >&2; usage >&2; exit 1; }
  gate
  require_clean
  git rev-parse --verify --quiet "$FROM^{commit}" >/dev/null 2>&1 \
    || { echo "branch-ops collect: ref '$FROM' не найден" >&2; exit 1; }
  git rev-list --reverse "HEAD..$FROM" > /tmp/branch_ops_pick.txt 2>/dev/null || true
  local total
  total="$(grep -c . /tmp/branch_ops_pick.txt 2>/dev/null || echo 0)"
  if [[ "$total" -eq 0 ]]; then
    echo '{"done": [], "nothing": true}' | python3 -c 'import json,sys; print(json.dumps({"done": [], "nothing": True}, ensure_ascii=False))'
    hint "hint: уникальных коммитов в '$FROM' нет — собирать нечего"
    return
  fi
  local done_json="[]" sha short
  while read -r sha; do
    [[ -n "$sha" ]] || continue
    if pick_one "$sha"; then
      short="$(git rev-parse --short "$sha" 2>/dev/null || echo "$sha")"
      done_json="$(echo "$done_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.append({"hash": sys.argv[1], "short": sys.argv[2]}); print(json.dumps(d))' "$sha" "$short")"
    else
      # СТОП без --quit/--abort: состояние оставить для разбора
      report_conflict "$sha" "$done_json"
      hint "hint: конфликт cherry-pick — разреши файлы, затем collect --continue или collect --abort (сам не чиню)"
      exit 2
    fi
  done < /tmp/branch_ops_pick.txt
  echo "$done_json" | python3 -c 'import json,sys; print(json.dumps({"done": json.load(sys.stdin), "nothing": False}, ensure_ascii=False))'
  hint "hint: collect готов — поштучно, проверь check/run.sh после каждого"
}

do_collect_continue() {
  gate_soft
  if ! GIT_EDITOR=true git cherry-pick --continue 2>&1 | tail -n 5 >&2; then
    local head_sha
    head_sha="$(git rev-parse CHERRY_PICK_HEAD 2>/dev/null || echo "?")"
    report_conflict "$head_sha" "[]"
    hint "hint: --continue упёрся в следующий конфликт — разбирай, затем снова collect --continue или collect --abort"
    exit 2
  fi
  # продолжить оставшиеся уникальные коммиты исходного --from
  if [[ -n "$FROM" ]]; then
    git rev-parse --verify --quiet "$FROM^{commit}" >/dev/null 2>&1 \
      || { echo "branch-ops collect --continue: ref '$FROM' не найден" >&2; exit 1; }
    git rev-list --reverse "HEAD..$FROM" > /tmp/branch_ops_pick.txt 2>/dev/null || true
    local done_json="[]" sha short
    while read -r sha; do
      [[ -n "$sha" ]] || continue
      if pick_one "$sha"; then
        short="$(git rev-parse --short "$sha" 2>/dev/null || echo "$sha")"
        done_json="$(echo "$done_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.append({"hash": sys.argv[1], "short": sys.argv[2]}); print(json.dumps(d))' "$sha" "$short")"
      else
        report_conflict "$sha" "$done_json"
        hint "hint: конфликт cherry-pick — разреши файлы, затем collect --continue или collect --abort"
        exit 2
      fi
    done < /tmp/branch_ops_pick.txt
    echo "$done_json" | python3 -c 'import json,sys; print(json.dumps({"done": json.load(sys.stdin), "continued": True}, ensure_ascii=False))'
  else
    echo '{"continued": true}' | python3 -c 'import json,sys; print(json.dumps({"continued": True, "done": []}, ensure_ascii=False))'
  fi
  hint "hint: --continue завершён"
}

do_collect_abort() {
  gate_soft
  git cherry-pick --abort 2>&1 | tail -n 3 >&2 || true
  echo '{"aborted": true}' | python3 -c 'import json; print(json.dumps({"aborted": True}, ensure_ascii=False))'
  hint "hint: cherry-pick откачен через scoped undo (--abort), ветка как до collect"
}

do_collect() {
  if [[ "$DO_ABORT" -eq 1 && "$DO_CONTINUE" -eq 1 ]]; then
    echo "branch-ops collect: --continue и --abort взаимоисключают" >&2; exit 1
  fi
  if [[ "$DO_ABORT" -eq 1 ]]; then do_collect_abort; return; fi
  if [[ "$DO_CONTINUE" -eq 1 ]]; then do_collect_continue; return; fi
  do_collect_fresh
}

# ---------- sync-base ----------
do_sync_base() {
  [[ -n "$ONTO" ]] || { echo "branch-ops sync-base: укажи --onto <B>" >&2; usage >&2; exit 1; }
  gate
  local branch out rc
  branch="$(git branch --show-current 2>/dev/null || echo "?")"
  set +e
  out="$(bash "$SCRIPT_DIR/../sync/rebase.sh" --onto "$ONTO" 2>&1)"
  rc=$?
  set -e
  echo "$out" | tail -n 15 > /tmp/branch_ops_rebase.txt 2>&1 || true
  if [[ $rc -eq 0 ]]; then
    python3 - "$branch" "$ONTO" << 'PY'
import json, sys
lines = open("/tmp/branch_ops_rebase.txt").read().splitlines()
print(json.dumps({"rebased": True, "branch": sys.argv[1], "base": sys.argv[2], "output": lines}, ensure_ascii=False))
PY
    hint "hint: пересажено через rebase --autostash, без merge-коммитов"
  else
    python3 - "$branch" "$ONTO" << 'PY'
import json, sys
lines = open("/tmp/branch_ops_rebase.txt").read().splitlines()
print(json.dumps({"rebased": False, "branch": sys.argv[1], "base": sys.argv[2], "output": lines, "hint": "rebase остановился (вероятно конфликт) — subagent → @conflict-resolver, затем git add + rebase --continue выполняет человек; либо откат: git rebase --abort"}, ensure_ascii=False))
PY
    hint "hint: rebase остановился — сам не чиню, дальше @conflict-resolver + человек"
    exit 2
  fi
}

case "$CMD" in
  fetch) do_fetch ;;
  preview) do_preview ;;
  collect) do_collect ;;
  sync-base) do_sync_base ;;
esac
