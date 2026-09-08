#!/usr/bin/env bash
# Шаг 1 пайплайна: определить провайдера (github|gitlab|gitea|bitbucket).
# Никакого LLM — чистая логика. Печатает имя провайдера в stdout, либо падает с ошибкой.
#
# Приоритет:
#   1. Явное поле `issue_provider:` в AGENTS.md (корень репозитория)
#   2. Автодетект по origin-remote (только для публичных известных хостов)
#
# Если хост self-hosted (gitea/gitlab на своём домене) — автодетект НЕ гадает,
# требует явного поля в AGENTS.md.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AGENTS_FILE="$REPO_ROOT/AGENTS.md"

# --- 1. Явное поле в AGENTS.md ---
if [[ -f "$AGENTS_FILE" ]]; then
  EXPLICIT="$(grep -iE '^issue_provider:' "$AGENTS_FILE" | head -n1 | sed -E 's/^[Ii]ssue_provider:[[:space:]]*//' | tr -d '\r' | xargs || true)"
  if [[ -n "${EXPLICIT:-}" ]]; then
    case "$EXPLICIT" in
      github|gitlab|gitea|bitbucket)
        echo "$EXPLICIT"
        exit 0
        ;;
      *)
        echo "detect-provider: неизвестное значение issue_provider в AGENTS.md: '$EXPLICIT'" >&2
        echo "Допустимые значения: github, gitlab, gitea, bitbucket" >&2
        exit 1
        ;;
    esac
  fi
fi

# --- 2. Автодетект по git remote origin ---
REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "$REMOTE_URL" ]]; then
  echo "detect-provider: не найден git remote 'origin' и нет issue_provider в AGENTS.md" >&2
  exit 1
fi

case "$REMOTE_URL" in
  *github.com*)
    echo "github"; exit 0 ;;
  *gitlab.com*)
    echo "gitlab"; exit 0 ;;
  *bitbucket.org*)
    echo "bitbucket"; exit 0 ;;
  *)
    echo "detect-provider: хост '$REMOTE_URL' не входит в список известных публичных хостов" >&2
    echo "Это, вероятно, self-hosted инстанс (gitea/gitlab/etc.) — автодетект по URL ненадёжен." >&2
    echo "Добавь в AGENTS.md строку:" >&2
    echo "  issue_provider: gitea   # или gitlab / github / bitbucket" >&2
    exit 1
    ;;
esac
