#!/usr/bin/env bash
# push — отправка в git remote ТОЛЬКО зафиксированных изменений.
#
# Философия как у остальных скриптов пака: агент не думает про git,
# а вызывает ровно одну команду и ретранслирует вывод.
# Скрипт намеренно умеет только `git push` уже существующих коммитов:
# здесь НЕТ и никогда не будет `add` / `commit` / `stash` / `checkout` /
# `reset` / `--force` / `--delete`. Незафиксированные файлы физически
# не могут уехать в remote — `git push` их не отправляет.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/push/run.sh [--remote <name>] [--dry-run]
#
# Коды выхода: 0 — отправлено или нечего отправлять; 1 — ошибка
# (не git-репозиторий, нет remote, detached HEAD, упал git push, ...).

set -euo pipefail

REMOTE="origin"
DRY_RUN=0

usage() {
  echo "Usage: run.sh [--remote <name>] [--dry-run]"
  echo "  Отправляет только зафиксированные коммиты текущей ветки в remote."
  echo "  Незафиксированные изменения остаются локально и никогда не пушатся."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
      echo "push: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# 1. Внутри ли мы git-репозитория.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "push: не git-репозиторий (запусти из корня проекта)" >&2; exit 1; }

TOP="$(git rev-parse --show-toplevel)"
BRANCH="$(git branch --show-current || true)"
if [[ -z "$BRANCH" ]]; then
  echo "push: detached HEAD — не отправляю. Переключись на ветку: git switch <branch>" >&2
  exit 1
fi

# 2. Remote существует.
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "push: remote '$REMOTE' не найден." >&2
  echo "Доступные remotes:" >&2
  git remote -v >&2 || true
  echo "Добавь его (вручную): git remote add $REMOTE <url>" >&2
  exit 1
fi

# 3. Показать состояние. Грязное дерево — это предупреждение, а не блокер:
#    git push всё равно отправит только коммиты.
echo "== состояние =="
echo "repo:   $TOP"
echo "branch: $BRANCH"
echo "remote: $REMOTE ($(git remote get-url "$REMOTE"))"
git status --short --branch
if [[ -n "$(git status --porcelain)" ]]; then
  echo "(!) Есть незафиксированные изменения — они НЕ будут отправлены, остаются только локально."
fi

# 4. Что именно уедет наверх (только коммиты).
#    Осторожно: upstream может быть настроен, но указывать в никуда
#    (например `origin/master [gone]` после клона пустого репозитория) —
#    тогда считаем это первой отправкой ветки.
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [[ -n "$UPSTREAM" ]] && git rev-parse --verify --quiet '@{u}' >/dev/null; then
  AHEAD="$(git rev-list --count '@{u}..HEAD')"
  BEHIND="$(git rev-list --count 'HEAD..@{u}')"
  echo "upstream: $UPSTREAM (ahead $AHEAD, behind $BEHIND)"
  if [[ "$AHEAD" -eq 0 ]]; then
    echo "Нечего отправлять: локальная ветка не опережает $UPSTREAM."
    exit 0
  fi
  echo "== коммиты к отправке ($UPSTREAM..HEAD) =="
  git log --oneline '@{u}..HEAD'
  PUSH_ARGS=(push "$REMOTE" "$BRANCH")
else
  echo "upstream: нет (первая отправка ветки)"
  echo "== последние коммиты ветки (верхние 10) =="
  git log --oneline -10
  PUSH_ARGS=(push --set-upstream "$REMOTE" "$BRANCH")
fi

# 5. Отправка.
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== dry-run: ничего не отправляю =="
  git push --dry-run "${PUSH_ARGS[@]:1}"
  echo "dry-run OK: коммиты готовы к отправке (см. выше)."
  exit 0
fi

echo "== отправка зафиксированных коммитов =="
git "${PUSH_ARGS[@]}"

echo "== итог =="
git status --short --branch
echo "Готово: зафиксированные коммиты ветки '$BRANCH' отправлены в '$REMOTE'."
