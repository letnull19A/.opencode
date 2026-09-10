#!/usr/bin/env bash
# sync — подтягивание из git remote ТОЛЬКО через `git pull --rebase --autostash`.
#
# Философия как у остальных скриптов пака: агент не думает про git,
# а вызывает ровно одну команду и ретранслирует вывод.
# Скрипт намеренно умеет только rebase-синк текущей ветки:
# здесь НЕТ и никогда не будет `merge`, `--force`, `reset --hard`,
# `checkout .`, `clean`, ручного `stash`, `push`. Незафиксированные
# изменения переживают синк через `--autostash` и возвращаются обратно
# автоматически — агент ничего не припрятывает и не достаёт сам.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/sync/run.sh [--remote <name>] [--dry-run]
#
# Коды выхода: 0 — подтянуто или нечего подтягивать; 1 — ошибка
# (не git-репозиторий, нет remote, detached HEAD, конфликт rebase, ...).

set -euo pipefail

REMOTE="origin"
DRY_RUN=0

usage() {
  echo "Usage: run.sh [--remote <name>] [--dry-run]"
  echo "  Подтягивает remote в текущую ветку только через pull --rebase --autostash."
  echo "  Незафиксированные изменения сохраняются автоматически, история не плодит merge-коммиты."
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
      echo "sync: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# 1. Внутри ли мы git-репозитория.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "sync: не git-репозиторий (запусти из корня проекта)" >&2; exit 1; }

TOP="$(git rev-parse --show-toplevel)"
BRANCH="$(git branch --show-current || true)"
if [[ -z "$BRANCH" ]]; then
  echo "sync: detached HEAD — не синкаю. Переключись на ветку: git switch <branch>" >&2
  exit 1
fi

# 2. Remote существует.
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "sync: remote '$REMOTE' не найден." >&2
  echo "Доступные remotes:" >&2
  git remote -v >&2 || true
  echo "Добавь его (вручную): git remote add $REMOTE <url>" >&2
  exit 1
fi

# 3. Показать состояние. Грязное дерево — не блокер: --autostash
#    припрячет изменения на время rebase и вернёт их обратно сам.
echo "== состояние =="
echo "repo:   $TOP"
echo "branch: $BRANCH"
echo "remote: $REMOTE ($(git remote get-url "$REMOTE"))"
git status --short --branch
if [[ -n "$(git status --porcelain)" ]]; then
  echo "(i) Есть незафиксированные изменения — переживут синк через --autostash."
fi

# 4. Upstream: если его нет, но ветка уже есть на remote — привязываемся.
#    Если ветки нет и там — подтягивать нечего.
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [[ -z "$UPSTREAM" ]] || ! git rev-parse --verify --quiet '@{u}' >/dev/null; then
  echo "upstream: нет — проверяю ветку '$BRANCH' на '$REMOTE'..."
  git fetch "$REMOTE" "$BRANCH" >/dev/null 2>&1 || true
  if git rev-parse --verify --quiet "refs/remotes/$REMOTE/$BRANCH" >/dev/null; then
    git branch --set-upstream-to="$REMOTE/$BRANCH" "$BRANCH"
    UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}')"
    echo "upstream: $UPSTREAM (привязан только что)"
  else
    echo "Нечего подтягивать: ветки '$BRANCH' на '$REMOTE' нет (возможно, её ещё не пушили — см. /push)."
    exit 0
  fi
fi

# 5. Что именно приедет сверху. fetch безопасен: трогает только
#    remote-tracking refs, рабочую копию и незафиксированное не меняет.
echo "== сверка с upstream ($UPSTREAM) =="
git fetch "$REMOTE"
AHEAD="$(git rev-list --count '@{u}..HEAD')"
BEHIND="$(git rev-list --count 'HEAD..@{u}')"
echo "upstream: $UPSTREAM (ahead $AHEAD, behind $BEHIND)"
if [[ "$BEHIND" -eq 0 ]]; then
  echo "Нечего подтягивать: локальная ветка уже актуальна."
  exit 0
fi
echo "== входящие коммиты (HEAD..$UPSTREAM, $BEHIND) =="
git log --oneline 'HEAD..@{u}'
if [[ "$AHEAD" -gt 0 ]]; then
  echo "(i) Локальных коммитов поверх: $AHEAD — после синка они перебазируются наверх, без merge-коммита."
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== dry-run: ничего не меняю =="
  echo "dry-run OK: выше — то, что приехало бы через pull --rebase --autostash."
  exit 0
fi

# 6. Синк. Только rebase, только autostash — других режимов у скрипта нет.
echo "== подтягиваю (pull --rebase --autostash) =="
if ! git pull --rebase --autostash "$REMOTE" "$BRANCH"; then
  if [[ -d "$(git rev-parse --git-dir)/rebase-merge" || -d "$(git rev-parse --git-dir)/rebase-apply" ]]; then
    echo "sync: rebase остановился на КОНФЛИКТЕ — скрипт дальше не идёт, ничего не чиню сам." >&2
    echo "Разреши вручную:" >&2
    echo "  1. git status — какие файлы в конфликте; правь их." >&2
    echo "  2. git add <файлы> && git rebase --continue (повторять до конца)" >&2
    echo "  3. Либо откат всего синка: git rebase --abort" >&2
  else
    echo "sync: git pull упал (см. выше). Скрипт не чиню — разбирай вывод." >&2
  fi
  exit 1
fi

echo "== итог =="
git status --short --branch
echo "== новые коммиты сверху (верхние 10) =="
git log --oneline -10
echo "Готово: ветка '$BRANCH' подтянута с '$REMOTE' через rebase, без merge-коммитов."
