#!/usr/bin/env bash
# run.sh — read-only разведка git для ИИ-агентов.
# Для ИИ — stdout только JSON, stderr — human hint (с --json тихо).
# Мутаций НЕТ: только git status/log/rev-parse/worktree list. Никаких
# fetch/merge/push/stash/checkout. Составные команды не нужны — скрипт
# сам собирает всё за один вызов (см. skills/git-recon, skills/branch-work).
#
# Использование (из любого места внутри репо, по одному вызову):
#   bash .opencode/scripts/git-recon/run.sh status [--json]
#   bash .opencode/scripts/git-recon/run.sh log [--ref <ref>] [--limit <n>] [--json]
#   bash .opencode/scripts/git-recon/run.sh base [--ref <name>] [--remote <name>] [--json]
#   bash .opencode/scripts/git-recon/run.sh whereami [--json]
#   bash .opencode/scripts/git-recon/run.sh verify [--expect-path <p>] [--expect-branch <b>] [--json]
#
#   status   — дерево: ветка, коммит, грязь, файлы (замена git status/rev-parse/branch).
#   log      — последние коммиты ref (по умолчанию HEAD, лимит 5).
#   base     — резолв базы для branch-work без fetch: heads/<ref> > remotes/<remote>/<ref>.
#   whereami — главный ответ «я в worktree?»: gitdir file|dir, запись в worktree list.
#   verify   — гейт изоляции branch-work: path совпал + это worktree + зарегистрирован + чисто.
#              Всегда exit 0, результат в поле isolated (false — стоп, не работать).

set -euo pipefail

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "git-recon: нужен '$1' (не найден в PATH)" >&2; exit 1; }; }
need_cmd git
need_cmd python3

CMD=""; REF=""; LIMIT="5"; REMOTE="origin"; EXPECT_PATH=""; EXPECT_BRANCH=""; JSON_ONLY=0

usage() {
  echo "Usage:"
  echo "  git-recon status [--json]"
  echo "  git-recon log [--ref <ref>] [--limit <n>] [--json]"
  echo "  git-recon base [--ref <name>] [--remote <name>] [--json]"
  echo "  git-recon whereami [--json]"
  echo "  git-recon verify [--expect-path <p>] [--expect-branch <b>] [--json]"
}

if [[ $# -eq 0 ]]; then usage >&2; exit 1; fi
if [[ "$1" == "-h" || "$1" == "--help" ]]; then usage; exit 0; fi
CMD="$1"; shift
case "$CMD" in status|log|base|whereami|verify) ;; *) echo "git-recon: неизвестная команда '$CMD'" >&2; usage >&2; exit 1 ;; esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="${2:?--ref требует значение}"; shift 2 ;;
    --limit) LIMIT="${2:?--limit требует число}"; shift 2 ;;
    --remote) REMOTE="${2:?--remote требует имя}"; shift 2 ;;
    --expect-path) EXPECT_PATH="${2:?--expect-path требует путь}"; shift 2 ;;
    --expect-branch) EXPECT_BRANCH="${2:?--expect-branch требует имя ветки}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "git-recon: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

hint() { if [[ $JSON_ONLY -eq 0 ]]; then echo "$@" >&2; fi; }

TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TOPLEVEL="${TOPLEVEL%/}"

gitdir_type() {
  if [[ -f "$TOPLEVEL/.git" ]]; then echo "file";
  elif [[ -d "$TOPLEVEL/.git" ]]; then echo "dir";
  else echo "none"; fi
}

gitdir_target() {
  if [[ -f "$TOPLEVEL/.git" ]]; then head -n 1 "$TOPLEVEL/.git" 2>/dev/null || echo "";
  else echo ""; fi
}

cur_branch() { git -C "$TOPLEVEL" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?"; }
cur_commit() { git -C "$TOPLEVEL" rev-parse --short HEAD 2>/dev/null || echo "?"; }
porcelain() { git -C "$TOPLEVEL" status --porcelain 2>/dev/null || echo ""; }

do_status() {
  local gt branch commit raw
  gt="$(gitdir_type)"
  branch="$(cur_branch)"
  commit="$(cur_commit)"
  raw="$(porcelain)"
  python3 - "$TOPLEVEL" "$gt" "$branch" "$commit" "$raw" << 'PY'
import json, sys
top, gt, branch, commit, raw = sys.argv[1:6]
lines = [l for l in raw.splitlines() if l.strip()]
is_wt = (gt == "file")
print(json.dumps({
  "toplevel": top,
  "gitdir_type": gt,
  "is_worktree": is_wt,
  "branch": branch,
  "commit": commit,
  "dirty": len(lines) > 0,
  "files": lines,
}, ensure_ascii=False))
PY
  hint "hint: gitdir file=worktree, dir=main; dirty=true → сначала /commit, не stash"
}

do_log() {
  local ref="${REF:-HEAD}" exists=0 log_out=""
  if git -C "$TOPLEVEL" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then exists=1; fi
  if [[ $exists -eq 1 ]]; then
    log_out="$(git -C "$TOPLEVEL" log --format='%H%x01%h%x01%s' -n "$LIMIT" "$ref" 2>/dev/null || true)"
  fi
  python3 - "$TOPLEVEL" "$ref" "$exists" "$LIMIT" "$log_out" << 'PY'
import json, sys
top, ref, exists, limit, out = sys.argv[1:6]
commits = []
if out.strip():
    for line in out.splitlines():
        parts = line.split("\x01")
        if len(parts) == 3:
            commits.append({"hash": parts[0], "short": parts[1], "subject": parts[2]})
print(json.dumps({
  "toplevel": top, "ref": ref,
  "exists": exists == "1", "limit": int(limit), "commits": commits,
}, ensure_ascii=False))
PY
  if [[ $exists -eq 0 ]]; then hint "hint: ref '$ref' не найден — не выдумывай хеш, спроси question"; fi
}

do_base() {
  local name="${REF:-dev}" resolved="" commit=""
  for cand in "refs/heads/$name" "refs/remotes/$REMOTE/$name"; do
    if git -C "$TOPLEVEL" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
      resolved="$cand"
      commit="$(git -C "$TOPLEVEL" rev-parse --short "$cand" 2>/dev/null || echo "?")"
      break
    fi
  done
  python3 - "$TOPLEVEL" "$name" "$REMOTE" "$resolved" "$commit" << 'PY'
import json, sys
top, name, remote, resolved, commit = sys.argv[1:6]
print(json.dumps({
  "toplevel": top, "requested": name, "remote": remote,
  "resolved_ref": resolved or None, "commit": commit or None,
  "exists": bool(resolved),
}, ensure_ascii=False))
PY
  if [[ -z "$resolved" ]]; then hint "hint: базы '$name' нет ни локально, ни на $REMOTE — спроси question, не создавай ветки сам"; fi
}

do_whereami() {
  local gt target list_json
  gt="$(gitdir_type)"
  target="$(gitdir_target)"
  list_json="$(git -C "$TOPLEVEL" worktree list --porcelain 2>/dev/null || echo "")"
  python3 - "$TOPLEVEL" "$gt" "$target" "$list_json" "$(cur_branch)" "$(cur_commit)" << 'PY'
import json, sys
top, gt, target, porcelain, branch, commit = sys.argv[1:7]
paths, main_path = [], None
cur = None
for line in porcelain.splitlines():
    if line.startswith("worktree "):
        cur = line[len("worktree "):].strip()
        paths.append(cur)
        if main_path is None:
            main_path = cur
registered = top in paths
print(json.dumps({
  "toplevel": top,
  "gitdir_type": gt,
  "gitdir_target": target or None,
  "is_worktree": gt == "file",
  "registered": registered,
  "main_path": main_path,
  "worktrees": paths,
  "branch": branch,
  "commit": commit,
}, ensure_ascii=False))
PY
  hint "hint: is_worktree=true (gitdir file) → изолирован; false (dir) → ты в main, мутаций веток нет"
}

do_verify() {
  local gt branch commit raw wlist exp_path=""
  gt="$(gitdir_type)"
  branch="$(cur_branch)"
  commit="$(cur_commit)"
  raw="$(porcelain)"
  wlist="$(git -C "$TOPLEVEL" worktree list --porcelain 2>/dev/null || echo "")"
  if [[ -n "$EXPECT_PATH" ]]; then
    exp_path="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$EXPECT_PATH")"
  fi
  python3 - "$TOPLEVEL" "$gt" "$branch" "$commit" "$raw" "$wlist" "$exp_path" "$EXPECT_BRANCH" << 'PY'
import json, sys
top, gt, branch, commit, raw, wlist, exp_path, exp_branch = sys.argv[1:9]
lines = [l for l in raw.splitlines() if l.strip()]
paths = [l[len("worktree "):].strip() for l in wlist.splitlines() if l.startswith("worktree ")]
checks = []
def add(name, ok, detail=""):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})
if exp_path:
    add("expect_path", exp_path == top, f"expect={exp_path} actual={top}")
else:
    add("expect_path", True, "не задан — пропуск")
add("is_worktree", gt == "file", f"gitdir_type={gt}")
add("registered", top in paths, f"worktrees={len(paths)}")
if exp_branch:
    add("expect_branch", exp_branch == branch, f"expect={exp_branch} actual={branch}")
else:
    add("expect_branch", True, "не задан — пропуск")
add("clean", len(lines) == 0, f"dirty_files={len(lines)}")
isolated = all(c["ok"] for c in checks)
print(json.dumps({
  "isolated": isolated, "toplevel": top, "branch": branch,
  "commit": commit, "checks": checks, "files": lines,
}, ensure_ascii=False))
PY
  hint "hint: isolated=false → СТОП, мутаций нет, отчёт родителю (не чинить обходами)"
}

case "$CMD" in
  status) do_status ;;
  log) do_log ;;
  base) do_base ;;
  whereami) do_whereami ;;
  verify) do_verify ;;
esac
