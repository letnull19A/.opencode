#!/usr/bin/env bash
# run.sh — управление git worktree для параллельной работы над проектом.
# Для ИИ — stdout только JSON, stderr — human hint. Для людей — таблицы.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/worktree/run.sh create --name <name> [--branch <branch>] [--from <base>] [--path <path>] [--json]
#   bash .opencode/scripts/worktree/run.sh list [--json]
#   bash .opencode/scripts/worktree/run.sh status --name <name> [--json]
#   bash .opencode/scripts/worktree/run.sh remove --name <name> [--force] [--json]
#   bash .opencode/scripts/worktree/run.sh prune [--json]
#
#   --name: идентификатор worktree, [A-Za-z0-9._-]+, используется как суффикс пути и ветки по умолчанию
#   --branch: имя git ветки (по умолчанию = <name>). Если ветка существует — чекаут, иначе создаётся от --from
#   --from: база для новой ветки (по умолчанию HEAD, если есть origin/dev — dev, иначе HEAD)
#   --path: кастомный путь worktree (по умолчанию ../<basename>-<name> рядом с ROOT)
#   --force: для remove — удалить даже с незакоммиченными изменениями
#   --json: только JSON на stdout (иначе JSON + human таблица на stderr)

set -euo pipefail

# ---------- helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "worktree: нужен '$1' (не найден в PATH)" >&2; exit 1; }; }
need_cmd git
need_cmd python3

NAME=""; BRANCH=""; FROM=""; CUSTOM_PATH=""; FORCE=0; JSON_ONLY=0; CMD=""

usage() {
  echo "Usage:"
  echo "  worktree create --name <name> [--branch <branch>] [--from <base>] [--path <path>] [--json]"
  echo "  worktree list [--json]"
  echo "  worktree status --name <name> [--json]"
  echo "  worktree remove --name <name> [--force] [--json]"
  echo "  worktree prune [--json]"
}

# ---------- parse ----------
if [[ $# -eq 0 ]]; then usage >&2; exit 1; fi
if [[ "$1" == "-h" || "$1" == "--help" ]]; then usage; exit 0; fi
CMD="$1"; shift
case "$CMD" in create|list|status|remove|prune) ;; *) echo "worktree: неизвестная команда '$CMD'" >&2; usage >&2; exit 1 ;; esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:?--name требует значение}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch требует имя ветки}"; shift 2 ;;
    --from) FROM="${2:?--from требует базу}"; shift 2 ;;
    --path) CUSTOM_PATH="${2:?--path требует путь}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "worktree: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ROOT="${ROOT%/}"
BASENAME="$(basename "$ROOT")"
PARENT_DIR="$(dirname "$ROOT")"

# ---------- validation ----------
NAME_RE='^[A-Za-z0-9._-]+$'
if [[ "$CMD" == "create" || "$CMD" == "status" || "$CMD" == "remove" ]]; then
  [[ -n "$NAME" ]] || { echo "worktree: укажи --name" >&2; usage >&2; exit 1; }
  [[ "$NAME" =~ $NAME_RE ]] || { echo "worktree: --name '$NAME' — только буквы/цифры . _ -" >&2; exit 1; }
fi

# ---------- git helpers ----------
git_worktree_list_json() {
  # возвращает JSON массива worktrees через python
  git worktree list --porcelain | python3 -c '
import sys, json
trees=[]
cur={}
for line in sys.stdin:
    line=line.rstrip("\n")
    if not line:
        if cur:
            trees.append(cur)
            cur={}
        continue
    if line.startswith("worktree "):
        cur["path"]=line[len("worktree "):]
    elif line.startswith("HEAD "):
        cur["head"]=line[len("HEAD "):]
    elif line.startswith("branch "):
        cur["branch"]=line[len("branch "):]
    elif line.startswith("bare"):
        cur["bare"]=True
    elif line.startswith("detached"):
        cur["detached"]=True
if cur:
    trees.append(cur)
# дополняем git status для каждого
import subprocess
for t in trees:
    try:
        out=subprocess.run(["git","-C",t["path"],"status","--porcelain","--branch"], capture_output=True, text=True, timeout=3)
        t["status"]=out.stdout.strip()
        # branch из status если не было
        if "branch" not in t:
            for l in out.stdout.splitlines():
                if l.startswith("## "):
                    t["branch"]=l[2:].split("...")[0]
                    break
    except: t["status"]=""
    # commit
    try:
        out=subprocess.run(["git","-C",t["path"],"rev-parse","--short","HEAD"], capture_output=True, text=True, timeout=3)
        t["commit"]=out.stdout.strip()
    except: t["commit"]=""
print(json.dumps(trees, ensure_ascii=False))
'
}

resolve_worktree_path() {
  local name="$1"
  # ищем worktree по имени (суффикс пути или ветка) — deduplicate, только один путь
  {
    git worktree list --porcelain | python3 -c '
import sys
name=sys.argv[1]
for line in sys.stdin:
    if line.startswith("worktree "):
        path=line[len("worktree "):].strip()
        if path.endswith("-"+name) or path.endswith("/"+name):
            print(path)
            sys.exit(0)
' "$name" || true
    git_worktree_list_json | python3 -c '
import json, sys, os
name=sys.argv[1]
trees=json.load(sys.stdin)
for t in trees:
    p=t.get("path","")
    b=t.get("branch","")
    if b.endswith("/"+name) or b==f"refs/heads/{name}":
        print(p)
        sys.exit(0)
    if p.endswith("-"+name) or p.endswith("/"+name):
        print(p)
        sys.exit(0)
' "$name" || true
  } | grep -v "^$" | sort -u | head -n 1
}

default_branch() {
  # определяем базу: --from > origin/dev > dev > HEAD
  if [[ -n "$FROM" ]]; then echo "$FROM"; return; fi
  if git rev-parse --verify --quiet "origin/dev" >/dev/null; then echo "origin/dev"; return; fi
  if git rev-parse --verify --quiet "dev" >/dev/null; then echo "dev"; return; fi
  echo "HEAD"
}

# ---------- commands ----------
do_create() {
  local branch="$BRANCH"
  [[ -n "$branch" ]] || branch="$NAME"
  local base
  base="$(default_branch)"
  local wt_path
  if [[ -n "$CUSTOM_PATH" ]]; then
    wt_path="$CUSTOM_PATH"
  else
    wt_path="$PARENT_DIR/${BASENAME}-${NAME}"
  fi
  # нормализуем путь
  wt_path="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$wt_path")"

  if [[ -e "$wt_path" ]]; then
    echo "worktree: путь '$wt_path' уже существует" >&2; exit 1
  fi
  if git worktree list --porcelain | grep -q "worktree $wt_path"; then
    echo "worktree: worktree '$wt_path' уже зарегистрирован" >&2; exit 1
  fi

  # проверяем, существует ли ветка
  local branch_exists=0
  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then branch_exists=1; fi
  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null && [[ "$branch" == "$NAME" ]]; then
    # ветка уже есть — используем её
    :
  fi

  echo "== создаю worktree '$NAME' ==" >&2
  echo "path:   $wt_path" >&2
  echo "branch: $branch (exists=$branch_exists)" >&2
  echo "from:   $base" >&2

  local add_args=()
  if [[ "$branch_exists" -eq 1 ]]; then
    add_args=("$wt_path" "$branch")
  else
    add_args=(-b "$branch" "$wt_path" "$base")
  fi

  if ! git worktree add "${add_args[@]}" 2>&1 | tee /tmp/worktree_add.log >&2; then
    echo "worktree: git worktree add упал" >&2; cat /tmp/worktree_add.log >&2; exit 1
  fi

  # инициализируем сабмодули (например .opencode)
  if [[ -f "$ROOT/.gitmodules" ]]; then
    echo "== инициализирую сабмодули ==" >&2
    git -C "$wt_path" submodule update --init --recursive 2>&1 | head -n 20 >&2 || true
  fi

  # проверяем .trello-project
  if [[ -f "$wt_path/.trello-project" ]]; then
    echo "trello-project: $(cat "$wt_path/.trello-project" | head -n 2 | tr '\n' ' ')" >&2
  fi

  local commit
  commit="$(git -C "$wt_path" rev-parse --short HEAD 2>/dev/null || echo "?")"
  local json
  json=$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"path":sys.argv[2],"branch":sys.argv[3],"base":sys.argv[4],"commit":sys.argv[5]}, ensure_ascii=False))' "$NAME" "$wt_path" "$branch" "$base" "$commit")
  echo "$json"
  if [[ $JSON_ONLY -eq 0 ]]; then
    echo "hint: worktree '$NAME' готов — cd $wt_path && opencode (отдельная сессия)" >&2
    echo "hint: для ИИ: path=$wt_path branch=$branch — запускай bash с workdir=\$path" >&2
  fi
}

do_list() {
  local json
  json="$(git_worktree_list_json)"
  echo "$json" | python3 -c '
import json, sys, os
trees=json.load(sys.stdin)
# имя worktree — из ветки (refs/heads/<name>), fallback — суффикс пути после BASENAME-
for t in trees:
    p=t.get("path","")
    b=t.get("branch","") or ""
    name=""
    if b.startswith("refs/heads/"):
        name=b[len("refs/heads/"):]
    else:
        # fallback: суффикс пути после последнего "/" и после BASENAME-
        base=os.path.basename(p)
        # если base == BASENAME (main worktree), имя = basename
        if "-" in base:
            # пробуем отрезать префикс до первого "-"? Для Milesnear используем ветку
            # ветки уже нет, берём суффикс после BASENAME-
            # но BASENAME неизвестен в python, используем эвристику: всё после последнего "-" если ветка не помогла
            # для test-wt даст wt — поэтому лучше ветка
            name=base.split("-")[-1]
        else:
            name=base
        # если ветка была пустой (detached), используем path
        if not name:
            name=base
    t["name"]=name
    t["is_main"]=False
print(json.dumps({"worktrees": trees, "count": len(trees)}, ensure_ascii=False, indent=2))
' > /tmp/wt_list.json
  cat /tmp/wt_list.json
  if [[ $JSON_ONLY -eq 0 ]]; then
    python3 -c '
import json, sys
j=json.load(open("/tmp/wt_list.json"))
print(f"""hint: {j["count"]} worktrees""", file=sys.stderr)
for t in j["worktrees"]:
    name=t.get("name","?")
    path=t.get("path","?")
    branch=t.get("branch","?")
    commit=t.get("commit","")[:7]
    print(f"  {name} -> {path} [{branch} {commit}]", file=sys.stderr)
' 2>&1 || true
    # помечаем main
    cat /tmp/wt_list.json | python3 -c 'import json; j=json.load(open("/tmp/wt_list.json")); j["worktrees"][0]["is_main"]=True if j["worktrees"] else None; print(json.dumps(j, ensure_ascii=False, indent=2))' > /tmp/wt_list2.json && cat /tmp/wt_list2.json > /tmp/wt_list.json
  fi
}

do_status() {
  local wt_path
  wt_path="$(resolve_worktree_path "$NAME")"
  if [[ -z "$wt_path" ]]; then
    echo "worktree: не найден worktree с именем '$NAME' (проверь list)" >&2; exit 1
  fi
  # собираем инфо
  git -C "$wt_path" status --porcelain --branch > /tmp/wt_status.txt 2>&1 || true
  git -C "$wt_path" rev-parse --short HEAD > /tmp/wt_commit.txt 2>&1 || echo "?" > /tmp/wt_commit.txt
  git -C "$wt_path" rev-parse --abbrev-ref HEAD > /tmp/wt_branch.txt 2>&1 || echo "detached" > /tmp/wt_branch.txt
  python3 - "$NAME" "$wt_path" << 'PY'
import json, sys, pathlib
name=sys.argv[1]; path=sys.argv[2]
branch=open("/tmp/wt_branch.txt").read().strip()
commit=open("/tmp/wt_commit.txt").read().strip()
status=open("/tmp/wt_status.txt").read().strip()
# парсим modified/untracked
lines=status.splitlines()
# первая строка — ветка
branch_line=lines[0] if lines and lines[0].startswith("##") else ""
files=lines[1:] if lines and lines[0].startswith("##") else lines
print(json.dumps({"name":name,"path":path,"branch":branch,"commit":commit,"branch_status":branch_line,"files":files,"dirty":len(files)>0,"status_raw":status}, ensure_ascii=False, indent=2))
PY
}

do_remove() {
  local wt_path
  wt_path="$(resolve_worktree_path "$NAME")"
  if [[ -z "$wt_path" ]]; then
    echo "worktree: не найден worktree с именем '$NAME'" >&2; exit 1
  fi
  echo "== удаляю worktree '$NAME' ($wt_path) ==" >&2
  local args=("$wt_path")
  [[ "$FORCE" -eq 1 ]] && args+=("--force")
  # закрываем, если есть незакоммиченные — без --force упадёт с подсказкой
  if ! git worktree remove "${args[@]}" 2>&1 | tee /tmp/wt_remove.log >&2; then
    echo "worktree: нужен --force для грязного worktree" >&2; exit 1
  fi
  git worktree prune 2>&1 | head >&2 || true
  # также удаляем ветку, если она была создана и не нужна? Не удаляем автоматически — спроси
  python3 -c 'import json,sys; print(json.dumps({"removed":sys.argv[1],"path":sys.argv[2]}, ensure_ascii=False))' "$NAME" "$wt_path"
  if [[ $JSON_ONLY -eq 0 ]]; then
    echo "hint: worktree '$NAME' удалён, ветка '$NAME' осталась (удали вручную: git branch -D $NAME если не нужна)" >&2
  fi
}

do_prune() {
  git worktree prune -v 2>&1 | tee /tmp/wt_prune.log >&2 || true
  local json
  json="$(git_worktree_list_json)"
  echo "$json" | python3 -c 'import json,sys; trees=json.load(sys.stdin); print(json.dumps({"pruned":True,"worktrees":trees}, ensure_ascii=False, indent=2))'
}

case "$CMD" in
  create) do_create ;;
  list) do_list ;;
  status) do_status ;;
  remove) do_remove ;;
  prune) do_prune ;;
esac
