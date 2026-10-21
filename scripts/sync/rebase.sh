#!/usr/bin/env bash
# rebase.sh — пересадка текущей ветки на свежую базу ТОЛЬКО через rebase.
#
# Философия как у sync/run.sh: агент не думает про git, а вызывает ровно одну
# команду и ретранслирует вывод. Здесь НЕТ и никогда не будет `merge`,
# `--force`, `reset --hard`, `checkout .`, `clean`, ручного `stash`, `push`.
# Незафиксированные изменения переживают пересадку через `--autostash`.
# Конфликт — стоп без самолечения: дальше `task` → `@conflict-resolver`
# с контекстом задачи (предложение попайлово), а `git add` +
# `git rebase --continue` выполняет только человек.
#
# Когда использовать: ветка отстала от dev (или другой базы) и конфликт —
# следствие порядка коммитов, а не содержания. Если изменения пересекаются
# по содержанию — это не сюда, а сразу к `@conflict-resolver`.
#
# Использование (из корня репозитория или worktree):
#   bash .opencode/scripts/sync/rebase.sh --onto <base> [--remote <name>] [--dry-run]
#
# Коды выхода: 0 — пересажено или нечего пересаживать; 1 — ошибка
# (не git-репозиторий, нет remote/base, detached HEAD, конфликт rebase, ...).

set -euo pipefail

ONTO=""
REMOTE="origin"
DRY_RUN=0

usage() {
  echo "Usage: rebase.sh --onto <base> [--remote <name>] [--dry-run]"
  echo "  Пересаживает текущую ветку на свежую <base> только через rebase --autostash."
  echo "  Конфликт — стоп, дальше @conflict-resolver + человек (add + continue)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --onto)
      ONTO="${2:?--onto требует имя ветки}"
      shift 2
      ;;
    --remote)
      REMOTE="${2:?--remote требует имя remote}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "rebase: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$ONTO" ]] || { echo "rebase: укажи --onto <base>" >&2; usage >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "rebase: не git-репозиторий (запусти из корня проекта или worktree)" >&2; exit 1; }

TOP="$(git rev-parse --show-toplevel)"
BRANCH="$(git branch --show-current || true)"
if [[ -z "$BRANCH" ]]; then
  echo "rebase: detached HEAD — не пересаживаю. Переключись на ветку: git switch <branch>" >&2
  exit 1
fi
if [[ "$BRANCH" == "$ONTO" ]]; then
  echo "rebase: уже на ветке '$ONTO' — пересаживать нечего." >&2
  exit 0
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "rebase: remote '$REMOTE' не найден." >&2
  echo "Доступные remotes:" >&2
  git remote -v >&2 || true
  exit 1
fi

echo "== состояние =="
echo "repo:   $TOP"
echo "branch: $BRANCH → onto: $ONTO"
echo "remote: $REMOTE ($(git remote get-url "$REMOTE"))"
git status --short --branch
if [[ -n "$(git status --porcelain)" ]]; then
  echo "(i) Есть незафиксированные изменения — переживут пересадку через --autostash."
fi

# Свежая база: remote-tracking приоритетнее локальной (локальная могла отстать).
echo "== сверка с базой =="
git fetch "$REMOTE" 2>&1 | head -n 5 || true
TARGET=""
if [[ "$ONTO" == *"/"* ]]; then
  # явный ref (origin/main, refs/heads/...) — как есть, без угадываний
  if ! git rev-parse --verify --quiet "$ONTO" >/dev/null; then
    echo "rebase: база '$ONTO' не найдена." >&2
    exit 1
  fi
  TARGET="$ONTO"
elif git rev-parse --verify --quiet "refs/remotes/$REMOTE/$ONTO" >/dev/null; then
  TARGET="$REMOTE/$ONTO"
elif git rev-parse --verify --quiet "refs/heads/$ONTO" >/dev/null; then
  TARGET="$ONTO"
else
  echo "rebase: база '$ONTO' не найдена ни локально, ни на '$REMOTE'." >&2
  exit 1
fi
echo "target: $TARGET ($(git rev-parse --short "$TARGET"))"
AHEAD="$(git rev-list --count "$TARGET..HEAD")"
BEHIND="$(git rev-list --count "HEAD..$TARGET")"
echo "впереди базы: $AHEAD, позади базы: $BEHIND"
if [[ "$BEHIND" -eq 0 ]]; then
  echo "Нечего пересаживать: ветка уже поверх свежей базы."
  exit 0
fi
echo "== накатываю $BEHIND коммитов базы, поверх — $AHEAD локальных =="
git log --oneline "HEAD..$TARGET" | head -n 10

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== dry-run: ничего не меняю =="
  echo "dry-run OK: выше — то, что приехало бы через rebase --autostash $TARGET."
  exit 0
fi

echo "== пересаживаю (rebase --autostash $TARGET) =="
if ! git rebase --autostash "$TARGET"; then
  if [[ -d "$(git rev-parse --git-dir)/rebase-merge" || -d "$(git rev-parse --git-dir)/rebase-apply" ]]; then
    echo "rebase: остановился на КОНФЛИКТЕ — скрипт дальше не идёт, ничего не чиню сам." >&2
    echo "Дальше:" >&2
    echo "  1. git status — какие файлы в конфликте." >&2
    echo "  2. subagent → @conflict-resolver с контекстом задачи (предложит разрешение попайлово)." >&2
    echo "  3. git add <файлы> && git rebase --continue (повторять до конца) — только человек." >&2
    echo "  4. Либо откат пересадки: git rebase --abort" >&2
  else
    echo "rebase: git rebase упал (см. выше). Скрипт не чиню — разбирай вывод." >&2
  fi
  exit 1
fi

echo "== итог =="
git status --short --branch
echo "== верхние коммиты (10) =="
git log --oneline -10
echo "Готово: ветка '$BRANCH' пересажена на '$TARGET' через rebase, без merge-коммитов."
