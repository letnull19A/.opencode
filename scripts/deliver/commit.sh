#!/usr/bin/env bash
# deliver/commit.sh — коммитит изменения ран пайплайна локально.
#
# Дополняет оба существующих правила:
#   - push/run.sh умеет ТОЛЬКО git push (add/commit запрещены) — поэтому
#     отдельный скрипт для коммита результатов автоматической доставки;
#   - /commit (скилл) остаётся для человека-агента, а этот скрипт закрывает
#     программную доставку (DELIVERY_ENABLED=1).
# Скрипт НЕ пушит: отправка — только отдельным вызовом push/run.sh.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/deliver/commit.sh --message "<msg>" [--dry-run]
#
# Коды выхода: 0 — закоммичено или нечего коммитить; 1 — ошибка.

set -euo pipefail

MESSAGE=""
DRY_RUN=0

usage() {
  echo "Usage: run.sh --message <msg> [--dry-run]"
  echo "  Коммитит ВСЕ незакоммиченные изменения текущей ветки (git add -A + git commit)."
  echo "  Не пушит. Пуш — отдельно: bash .opencode/scripts/push/run.sh [--remote <name>]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message)
      MESSAGE="${2:?--message требует текст}"
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
      echo "deliver/commit: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$MESSAGE" ]] || { echo "deliver/commit: --message обязателен" >&2; usage >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "deliver/commit: не git-репозиторий" >&2; exit 1; }

BRANCH="$(git branch --show-current || true)"
if [[ -z "$BRANCH" ]]; then
  echo "deliver/commit: detached HEAD — не коммичу. Переключись на ветку." >&2
  exit 1
fi

# Без изменений не создаём пустых коммитов.
if [[ -z "$(git status --porcelain)" ]]; then
  echo "deliver/commit: нечего коммитить."
  exit 0
fi

echo "== состояние =="
git status --short --branch

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== dry-run: add + commit не выполняются =="
  git diff --stat
  exit 0
fi

git add -A
if git commit -m "$MESSAGE"; then
  echo "== итог =="
  git log --oneline -1
  echo "deliver/commit: закоммичено."
else
  echo "deliver/commit: коммит не создан (см. вывод выше)." >&2
  exit 1
fi