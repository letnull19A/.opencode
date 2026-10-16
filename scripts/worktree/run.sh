#!/usr/bin/env bash
# run.sh — управление git worktree для параллельной работы над проектом.
# Для ИИ — stdout только JSON, stderr — human hint. Для людей — таблицы.
#
# Использование (из корня проекта):
#   bash .opencode/scripts/worktree/run.sh create --name <name> [--branch <branch>] [--from <base>] [--path <path>] [--json]
#   bash .opencode/scripts/worktree/run.sh list [--json]
#   bash .opencode/scripts/worktree/run.sh status --name <name> [--json]
#   bash .opencode/scripts/worktree/run.sh remove --name <name> [--force] [--json]
#   bash .opencode/scripts/worktree/run.sh done --name <name> [--branch <branch>] [--base <base>] [--remote <name>] [--keep-branch] [--force] [--json]
#   bash .opencode/scripts/worktree/run.sh prune [--json]
#
#   done — завершение жизненного цикла задачи: гейт PR (только MERGED,
#   CLOSED — только с --force) + чистый worktree → удалить worktree →
#   удалить локальную ветку (если вмержена) → подтянуть base в основном
#   репозитории (fetch + rebase без merge-коммитов). Вызывать из основного
#   репозитория, не изнутри самого worktree.
#
#   --name: идентификатор worktree, [A-Za-z0-9._-]+, используется как суффикс пути и ветки по умолчанию
#   --branch: имя git ветки (по умолчанию = <name>). Если ветка существует — чекаут, иначе создаётся от --from
#   --from: база для новой ветки (по умолчанию центральная dev-ветка:
#     dev → origin/dev → develop → origin/develop; нет обеих — скрипт
#     создаст локальный dev от main, main не трогает, ничего не пушит)
#   --path: кастомный путь worktree (по умолчанию ../<basename>-<name> рядом с ROOT)
#   --force: для remove — удалить даже с незакоммиченными изменениями;
#     для done — также разрешить CLOSED-PR и удаление невмерженной ветки (-D)
#   --base: целевая ветка для done-синка (по умолчанию центральная dev-ветка;
#     main — только явным --base, PR в main создаёт только пользователь)
#   --remote: git remote для done (по умолчанию origin)
#   --keep-branch: для done — не удалять локальную ветку после очистки
#   --json: только JSON на stdout (иначе JSON + human таблица на stderr)

set -euo pipefail

# ---------- helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "worktree: нужен '$1' (не найден в PATH)" >&2; exit 1; }; }
need_cmd git
need_cmd python3

NAME=""; BRANCH=""; BASE=""; REMOTE="origin"; FROM=""; CUSTOM_PATH=""; FORCE=0; JSON_ONLY=0; KEEP_BRANCH=0; CMD=""

usage() {
  echo "Usage:"
  echo "  worktree create --name <name> [--branch <branch>] [--from <base>] [--path <path>] [--json]"
  echo "  worktree list [--json]"
  echo "  worktree status --name <name> [--json]"
  echo "  worktree remove --name <name> [--force] [--json]"
  echo "  worktree done --name <name> [--branch <branch>] [--base <base>] [--remote <name>] [--keep-branch] [--force] [--json]"
  echo "  worktree prune [--json]"
}

# ---------- parse ----------
if [[ $# -eq 0 ]]; then usage >&2; exit 1; fi
if [[ "$1" == "-h" || "$1" == "--help" ]]; then usage; exit 0; fi
CMD="$1"; shift
case "$CMD" in create|list|status|remove|done|prune) ;; *) echo "worktree: неизвестная команда '$CMD'" >&2; usage >&2; exit 1 ;; esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:?--name требует значение}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch требует имя ветки}"; shift 2 ;;
    --base) BASE="${2:?--base требует имя ветки}"; shift 2 ;;
    --remote) REMOTE="${2:?--remote требует имя remote}"; shift 2 ;;
    --keep-branch) KEEP_BRANCH=1; shift ;;
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- validation ----------
NAME_RE='^[A-Za-z0-9._-]+$'
if [[ "$CMD" == "create" || "$CMD" == "status" || "$CMD" == "remove" || "$CMD" == "done" ]]; then
  [[ -n "$NAME" ]] || { echo "worktree: укажи --name" >&2; usage >&2; exit 1; }
  [[ "$NAME" =~ $NAME_RE ]] || { echo "worktree: --name '$NAME' — только буквы/цифры . _ -" >&2; exit 1; }
fi

default_done_base() {
  # база для done-синка: явный --base > центральная dev-ветка.
  # main — только явным --base (PR в main создаёт только пользователь).
  if [[ -n "$BASE" ]]; then echo "$BASE"; return; fi
  ensure_central_branch
}

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
  # определяем базу для create: явный --from > центральная dev-ветка.
  # main здесь никогда не дефолт: работа идёт только на dev/develop,
  # PR в main создаёт только пользователь.
  if [[ -n "$FROM" ]]; then echo "$FROM"; return; fi
  ensure_central_branch
}

ensure_central_branch() {
  # Центральная ветка репозитория: dev > develop.
  # Нет обеих — создать локальный dev от main (только локально, без push).
  # Печатает имя ветки на stdout, пояснения — на stderr.
  if git rev-parse --verify --quiet "refs/heads/dev" >/dev/null; then echo "dev"; return; fi
  if git rev-parse --verify --quiet "refs/remotes/$REMOTE/dev" >/dev/null; then echo "dev"; return; fi
  if git rev-parse --verify --quiet "refs/heads/develop" >/dev/null; then echo "develop"; return; fi
  if git rev-parse --verify --quiet "refs/remotes/$REMOTE/develop" >/dev/null; then echo "develop"; return; fi
  local src=""
  if git rev-parse --verify --quiet "refs/heads/main" >/dev/null; then src="main";
  elif git rev-parse --verify --quiet "refs/remotes/$REMOTE/main" >/dev/null; then src="$REMOTE/main";
  else src="HEAD"; fi
  echo "== центральной ветки dev/develop нет — создаю локальный dev от $src (main не трогаю, без push) ==" >&2
  if git branch dev "$src" 2>&1 | head -n 3 >&2; then echo "dev"; return; fi
  if git rev-parse --verify --quiet "refs/heads/dev" >/dev/null; then echo "dev"; return; fi
  echo "worktree: не смог создать dev — работаю от HEAD" >&2
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

  # проверяем .devbox (ранее .devbox-project / .trello-project)
  if [[ -f "$wt_path/.devbox" ]]; then
    echo "devbox: $(cat "$wt_path/.devbox" | head -n 2 | tr '\n' ' ')" >&2
  elif [[ -f "$wt_path/.devbox-project" ]]; then
    echo "devbox: legacy .devbox-project найден — мигрируй: bash .opencode/scripts/task-manager/migrate.sh" >&2
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

do_done() {
  # Завершение жизненного цикла задачи. Гейты (fail-closed):
  #   1. worktree чист (иначе сначала /commit, либо --force с потерей незакоммиченного)
  #   2. PR ветки в терминальном состоянии (MERGED; CLOSED — только с --force)
  # Дальше: удалить worktree → удалить локальную ветку (если вмержена)
  # → подтянуть base в основном репозитории (fetch + rebase, без merge-коммитов).
  # Здесь НЕТ merge, --force-пуша, stash, reset --hard, checkout . — как и в sync.
  local wt_path
  wt_path="$(resolve_worktree_path "$NAME" || true)"
  if [[ -z "$wt_path" ]]; then
    echo "worktree done: не найден worktree с именем '$NAME' (проверь list)" >&2; exit 1
  fi
  if [[ "$ROOT" == "$wt_path" ]]; then
    echo "worktree done: запущен изнутри самого worktree — перейди в основной репозиторий и повтори" >&2; exit 1
  fi
  local wt_branch="$BRANCH"
  if [[ -z "$wt_branch" ]]; then
    wt_branch="$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi
  if [[ -z "$wt_branch" || "$wt_branch" == "HEAD" ]]; then
    echo "worktree done: не смог определить ветку worktree (detached?) — укажи --branch явно" >&2; exit 1
  fi

  # 1. Чистота worktree.
  local dirty
  dirty="$(git -C "$wt_path" status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" && "$FORCE" -eq 0 ]]; then
    echo "worktree done: в worktree есть незафиксированные изменения — сначала /commit, либо повтори с --force (незакоммиченное будет потеряно)" >&2
    echo "$dirty" >&2
    exit 1
  fi

  # 2. PR-гейт: только терминальное состояние (read-only проверка).
  if [[ ! -x "$SCRIPT_DIR/../pr/status-pr.sh" ]]; then
    echo "worktree done: нет scripts/pr/status-pr.sh — не могу проверить PR, стоп" >&2; exit 1
  fi
  local status_out="" lifecycle=""
  status_out="$(bash "$SCRIPT_DIR/../pr/status-pr.sh" --branch "$wt_branch" 2>/dev/null || true)"
  lifecycle="$(echo "$status_out" | grep -E '^LIFECYCLE: ' | awk '{print $2}' || true)"
  if [[ "$lifecycle" != "MERGED" && ! ("$lifecycle" == "CLOSED" && "$FORCE" -eq 1) ]]; then
    echo "worktree done: PR ветки '$wt_branch' не завершён (LIFECYCLE: ${lifecycle:-unknown}) — чищу только после MERGED (CLOSED — только с --force)" >&2
    echo "$status_out" >&2
    exit 1
  fi
  echo "== PR-гейт пройден: $wt_branch → $lifecycle ==" >&2

  # Base резолвим только после гейтов: ensure_central_branch может
  # создать локальный dev, а до пройденных гейтов сайд-эффектов быть не должно.
  local base
  base="$(default_done_base)"
  if [[ -z "$base" ]]; then
    echo "worktree done: не смог определить base-ветку — укажи --base явно" >&2; exit 1
  fi

  # 3. Удалить worktree.
  echo "== удаляю worktree '$NAME' ($wt_path) ==" >&2
  local rm_args=("$wt_path")
  [[ "$FORCE" -eq 1 ]] && rm_args+=("--force")
  if ! git worktree remove "${rm_args[@]}" 2>&1 | tee /tmp/wt_remove.log >&2; then
    echo "worktree done: не смог удалить worktree" >&2; exit 1
  fi
  git worktree prune 2>&1 | head >&2 || true

  # 4. Удалить локальную ветку — только если её коммиты уже на remote base.
  local branch_deleted=0
  if [[ "$KEEP_BRANCH" -eq 1 ]]; then
    echo "keep-branch: ветку '$wt_branch' оставляю по флагу" >&2
  elif [[ "$wt_branch" == "$base" ]]; then
    echo "ветка worktree совпадает с base ($base) — удалять нечего" >&2
  else
    git fetch "$REMOTE" 2>&1 | head -n 5 >&2 || true
    if git merge-base --is-ancestor "$wt_branch" "$REMOTE/$base" 2>/dev/null; then
      git branch -D "$wt_branch" 2>&1 | head -n 3 >&2 && branch_deleted=1 || true
    elif [[ "$FORCE" -eq 1 ]]; then
      echo "ветка '$wt_branch' не вмержена в $REMOTE/$base — --force: удаляю через -D" >&2
      git branch -D "$wt_branch" 2>&1 | head -n 3 >&2 && branch_deleted=1 || true
    else
      echo "hint: ветка '$wt_branch' не вмержена в $REMOTE/$base — оставляю (проверь diff, удали вручную: git branch -D $wt_branch)" >&2
    fi
  fi

  # 5. Подтянуть base в основном репозитории (только если он уже на base).
  local synced=0
  local cur
  cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$cur" == "$base" ]]; then
    if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
      echo "(i) В основном репозитории есть незафиксированные изменения — переживут синк через --autostash." >&2
    fi
    if git pull --rebase --autostash "$REMOTE" "$base" 2>&1 | tail -n 5 >&2; then
      synced=1
    else
      echo "worktree done: worktree удалён, а подтянуть $base не смог (конфликт?) — разрешение вручную:" >&2
      echo "  1. git status — какие файлы в конфликте; правь их." >&2
      echo "  2. git add <файлы> && git rebase --continue (повторять до конца)" >&2
      echo "  3. Либо откат синка: git rebase --abort" >&2
    fi
  else
    git fetch "$REMOTE" 2>&1 | head -n 5 >&2 || true
    echo "hint: основной репозиторий на ветке '$cur', а не на $base — подтяни вручную: git switch $base && bash .opencode/scripts/sync/run.sh" >&2
  fi

  python3 -c 'import json,sys; print(json.dumps({"done":sys.argv[1],"path":sys.argv[2],"branch":sys.argv[3],"base":sys.argv[4],"pr_lifecycle":sys.argv[5],"removed":True,"branch_deleted":sys.argv[6]=="1","synced":sys.argv[7]=="1"}, ensure_ascii=False))' "$NAME" "$wt_path" "$wt_branch" "$base" "$lifecycle" "$branch_deleted" "$synced"
  if [[ $JSON_ONLY -eq 0 ]]; then
    if [[ "$synced" -eq 1 ]]; then
      echo "hint: жизненный цикл '$NAME' завершён — worktree удалён, base '$base' подтянут" >&2
    else
      echo "hint: жизненный цикл '$NAME' завершён — worktree удалён (синк base см. выше)" >&2
    fi
  fi
}

case "$CMD" in
  create) do_create ;;
  list) do_list ;;
  status) do_status ;;
  remove) do_remove ;;
  done) do_done ;;
  prune) do_prune ;;
esac
