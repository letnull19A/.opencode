#!/usr/bin/env bash
# get-pr-url.sh — read-only поиск ссылки на открытый PR/MR текущей ветки.
# Никакого LLM, ничего не создаёт — только читает через готовые CLI/API.
# Гарантия контракта: при успехе в stdout всегда есть строка `PR_URL: <url>`
# либо `PR_URL: none`. Exit 0 — найден или не найден; 1 — фатальная ошибка
# (не git, нет provider, нет CLI). Скрипт никогда не падает из-за отсутствия
# PR — это штатный случай `PR_URL: none`.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/pr/get-pr-url.sh [--branch <name>] [--remote <name>]
#
# Примеры:
#   bash .opencode/scripts/pr/get-pr-url.sh
#   bash .opencode/scripts/pr/get-pr-url.sh --branch my-feature

set -euo pipefail

BRANCH=""
REMOTE="origin"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$DIR/../issue-writer/detect-provider.sh"

usage() {
  echo "Usage: get-pr-url.sh [--branch <name>] [--remote <name>]"
  echo "  Печатает PR_URL открытого PR/MR текущей ветки либо 'PR_URL: none'."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="${2:?--branch требует имя ветки}"
      shift 2
      ;;
    --remote)
      REMOTE="${2:?--remote требует имя remote}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "get-pr-url: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "get-pr-url: не git-репозиторий" >&2; exit 1; }

if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git branch --show-current || true)"
  if [[ -z "$BRANCH" ]]; then
    echo "get-pr-url: detached HEAD — ветка неизвестна" >&2
    exit 1
  fi
fi

PROVIDER="$("$DETECT" 2>/dev/null)" || {
  echo "get-pr-url: не смог определить провайдера (см. issue_provider в AGENTS.md)" >&2
  exit 1
}

URL=""

case "$PROVIDER" in
  github)
    command -v gh >/dev/null || { echo "get-pr-url: нужен gh: https://cli.github.com" >&2; exit 1; }
    # gh pr view умеет смотреть по ветке; head может быть local или origin/branch.
    URL="$(gh pr view "$BRANCH" --json url --jq .url 2>/dev/null || true)"
    if [[ -z "$URL" ]]; then
      URL="$(gh pr view --head "$BRANCH" --json url --jq .url 2>/dev/null || true)"
    fi
    ;;

  gitlab)
    command -v glab >/dev/null || { echo "get-pr-url: нужен glab: https://gitlab.com/gitlab-org/cli" >&2; exit 1; }
    # glab mr list --source-branch отдаёт JSON со списком; берём первый open.
    if glab mr list --source-branch "$BRANCH" --output json >/tmp/pr-list.json 2>/dev/null; then
      URL="$(python3 -c 'import json,sys; d=json.load(open("/tmp/pr-list.json")); print(d[0]["web_url"] if isinstance(d,list) and d else "")' 2>/dev/null || true)"
    fi
    if [[ -z "$URL" ]]; then
      URL="$(glab mr view --source-branch "$BRANCH" --output json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("web_url","") if isinstance(d,dict) else "")' 2>/dev/null || true)"
    fi
    ;;

  gitea)
    command -v tea >/dev/null || { echo "get-pr-url: нужен tea: https://gitea.com/gitea/tea" >&2; exit 1; }
    # tea разных версий: пробуем `pr list`, затем `pulls list`.
    if tea pr list --state open --output json >/tmp/pr-list.json 2>/dev/null; then
      URL="$(python3 -c 'import json; d=json.load(open("/tmp/pr-list.json")); print(next((x.get("html_url","") for x in (d if isinstance(d,list) else []) if x.get("head")==("'"$BRANCH"'") or "'" $BRANCH"'" in str(x)), ""))' 2>/dev/null || true)"
    fi
    if [[ -z "$URL" ]]; then
      # Фолбэк: текстовый вывод, ищем первую ссылку на /pulls/N для этой ветки.
      URL="$(tea pulls list --state open 2>/dev/null | grep -oE 'https://[^ ]+/pulls/[0-9]+' | head -n1 || true)"
    fi
    ;;

  bitbucket)
    : "${BITBUCKET_WORKSPACE:?нужен env BITBUCKET_WORKSPACE}" "${BITBUCKET_REPO_SLUG:?нужен env BITBUCKET_REPO_SLUG}" "${BITBUCKET_USERNAME:?нужен env BITBUCKET_USERNAME}" "${BITBUCKET_APP_PASSWORD:?нужен env BITBUCKET_APP_PASSWORD}"
    # Ищем открытый PR с source.branch.name == BRANCH.
    RESP="$(curl -sf -u "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" \
      "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests?q=state+%3D+%22OPEN%22+AND+source.branch.name+%3D+%22${BRANCH}%22" 2>/dev/null || true)"
    if [[ -n "$RESP" ]]; then
      URL="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); v=d.get("values",[]); print(v[0].get("links",{}).get("html",{}).get("href","") if v else "")' "$RESP" 2>/dev/null || true)"
    fi
    ;;

  *)
    echo "get-pr-url: неизвестный provider '$PROVIDER'" >&2
    exit 1
    ;;
esac

if [[ -n "$URL" ]]; then
  echo "PR_URL: $URL"
else
  echo "PR_URL: none"
  echo "(i) Открытый PR для ветки '$BRANCH' не найден (provider: $PROVIDER)." >&2
  echo "    Создай его: bash .opencode/scripts/pr/create-pr.sh --title \"<title>\" --base <base>" >&2
fi
exit 0
