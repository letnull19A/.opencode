#!/usr/bin/env bash
# create-pr.sh — создать PR/MR через готовый CLI/API и ГАРАНТИРОВАННО вывести ссылку.
# Никакого LLM. Контракт: при успехе последняя строка stdout — всегда `PR_URL: <url>`.
# Агент обязан ретранслировать эту строку пользователю как кликабельную ссылку.
# Если PR уже существует — не падаем, а возвращаем ссылку на существующий
# (тоже `PR_URL: <url>`, exit 0). Фатальная ошибка (нет CLI, нет remote,
# упал API) — ненулевой exit, PR_URL не печатаем.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/pr/create-pr.sh --title "<title>" [--body "<text>"]
#       [--body-file <file>] [--json <pr.json>] [--base <branch>] [--head <branch>]
#       [--draft] [--labels "a,b"] [--dry-run]
#
# Стандарт body: агент НЕ пишет текст свободной формой. Агент собирает JSON
# по schema/pr.schema.json, валидирует через validate-pr-data.py и передаёт
# сюда через --json — скрипт сам рендерит markdown через render-pr.py.
# --body / --body-file — только для исключений (hotfix без JSON).
#
# CLI-зависимости (как в issue-writer/create-issue.sh):
#   github   -> gh
#   gitlab   -> glab
#   gitea    -> tea
#   bitbucket -> REST через curl + env BITBUCKET_WORKSPACE/SLUG/USERNAME/APP_PASSWORD
#
# Примеры:
#   bash .opencode/scripts/pr/create-pr.sh --title "feat: add login" --base main
#   bash .opencode/scripts/pr/create-pr.sh --title "fix: crash" --body "Что чинит..." --draft

set -euo pipefail

TITLE=""
BODY=""
BODY_FILE=""
PR_JSON=""
BASE=""
HEAD=""
DRAFT=0
LABELS=""
DRY_RUN=0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$DIR/../issue-writer/detect-provider.sh"

usage() {
  echo "Usage: create-pr.sh --title <title> [--body <text> | --body-file <file> | --json <pr.json>]"
  echo "         [--base <branch>] [--head <branch>] [--draft] [--labels \"a,b\"] [--dry-run]"
  echo "  Создаёт PR/MR и всегда печатает 'PR_URL: <url>' при успехе."
  echo "  Стандарт: body только через --json (schema/pr.schema.json + render-pr.py)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      TITLE="${2:?--title требует текст}"
      shift 2
      ;;
    --body)
      BODY="${2:?--body требует текст}"
      shift 2
      ;;
    --body-file)
      BODY_FILE="${2:?--body-file требует путь}"
      shift 2
      ;;
    --json)
      PR_JSON="${2:?--json требует путь к pr.json}"
      shift 2
      ;;
    --base)
      BASE="${2:?--base требует имя ветки}"
      shift 2
      ;;
    --head)
      HEAD="${2:?--head требует имя ветки}"
      shift 2
      ;;
    --draft)
      DRAFT=1
      shift
      ;;
    --labels)
      LABELS="${2:?--labels требует csv}"
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
      echo "create-pr: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$TITLE" ]] || { echo "create-pr: --title обязателен" >&2; usage >&2; exit 1; }
SET_COUNT=0
[[ -n "$BODY" ]] && SET_COUNT=$((SET_COUNT + 1))
[[ -n "$BODY_FILE" ]] && SET_COUNT=$((SET_COUNT + 1))
[[ -n "$PR_JSON" ]] && SET_COUNT=$((SET_COUNT + 1))
if [[ "$SET_COUNT" -gt 1 ]]; then
  echo "create-pr: укажи что-то одно: --body, --body-file или --json" >&2
  exit 1
fi
if [[ -n "$BODY_FILE" ]]; then
  [[ -f "$BODY_FILE" ]] || { echo "create-pr: файл не найден: $BODY_FILE" >&2; exit 1; }
  BODY="$(cat "$BODY_FILE")"
fi
if [[ -n "$PR_JSON" ]]; then
  [[ -f "$PR_JSON" ]] || { echo "create-pr: файл не найден: $PR_JSON" >&2; exit 1; }
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "create-pr: не git-репозиторий" >&2; exit 1; }

if [[ -z "$HEAD" ]]; then
  HEAD="$(git branch --show-current || true)"
  [[ -n "$HEAD" ]] || { echo "create-pr: detached HEAD — укажи --head явно" >&2; exit 1; }
fi

# BASE по умолчанию: main, иначе master, иначе default-ветка remote.
if [[ -z "$BASE" ]]; then
  if git rev-parse --verify --quiet refs/heads/main >/dev/null; then
    BASE="main"
  elif git rev-parse --verify --quiet refs/heads/master >/dev/null; then
    BASE="master"
  else
    BASE="$(git remote show origin 2>/dev/null | grep -i 'HEAD branch' | awk '{print $NF}' || true)"
    [[ -n "$BASE" ]] || BASE="main"
  fi
fi

if [[ "$HEAD" == "$BASE" ]]; then
  echo "create-pr: head ($HEAD) совпадает с base ($BASE) — PR из ветки в саму себя не создают." >&2
  echo "Создай feature-ветку: git switch -c <name>" >&2
  exit 1
fi

PROVIDER="$("$DETECT")"
echo "→ provider: $PROVIDER, head: $HEAD, base: $BASE" >&2

# Стандартизированный body: рендерим из провалидированного JSON детерминированным шаблоном.
if [[ -n "$PR_JSON" ]]; then
  TMP_BODY="$(mktemp)"
  trap 'rm -f "$TMP_BODY"' EXIT
  python3 "$DIR/render-pr.py" "$PROVIDER" --json "$PR_JSON" --out "$TMP_BODY"
  BODY="$(cat "$TMP_BODY")"
  rm -f "$TMP_BODY"
  trap - EXIT
  # Labels из JSON — только если --labels не задан явно (явный флаг сильнее).
  if [[ -z "$LABELS" ]]; then
    LABELS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(d.get("labels",[])))' "$PR_JSON")"
  fi
  # Title из JSON должен совпадать с --title (защита от рассинхрона).
  JSON_TITLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["title"])' "$PR_JSON")"
  if [[ "$JSON_TITLE" != "$TITLE" ]]; then
    echo "create-pr: --title не совпадает с title в --json ('$TITLE' vs '$JSON_TITLE')" >&2
    exit 1
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== dry-run: PR не создаю =="
  echo "title: $TITLE"
  echo "head:  $HEAD → base: $BASE"
  [[ -n "$LABELS" ]] && echo "labels: $LABELS"
  [[ "$DRAFT" -eq 1 ]] && echo "draft: yes"
  if [[ -n "$BODY" ]]; then
    echo "--- BODY (preview) ---"
    echo "$BODY"
  fi
  echo "dry-run OK: выше — то, что ушло бы в $PROVIDER."
  exit 0
fi

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

# Извлекает первую PR/MR-ссылку из текста (github/gitlab/gitea/bitbucket форматы).
extract_url() {
  grep -oE 'https://[^[:space:]"]+/(pull|merge_requests|pulls)/[0-9]+' "$1" | head -n1 || true
}

print_or_fallback() {
  local url="$1"
  if [[ -n "$url" ]]; then
    echo "PR_URL: $url"
    return 0
  fi
  # Фолбэк: PR мог уже существовать — пробуем прочитать его read-only скриптом.
  echo "(i) Прямая ссылка не извлечена, пробую get-pr-url.sh..." >&2
  local found
  found="$(bash "$DIR/get-pr-url.sh" --branch "$HEAD" 2>/dev/null | grep -E '^PR_URL: ' | awk '{print $2}' || true)"
  if [[ -n "$found" && "$found" != "none" ]]; then
    echo "PR_URL: $found"
    return 0
  fi
  echo "create-pr: не смог получить ссылку на PR (см. вывод выше)" >&2
  return 1
}

case "$PROVIDER" in
  github)
    command -v gh >/dev/null || { echo "Нужен gh: https://cli.github.com" >&2; exit 2; }
    ARGS=(pr create --title "$TITLE" --base "$BASE" --head "$HEAD")
    if [[ -n "$BODY" ]]; then
      ARGS+=(--body "$BODY")
    else
      ARGS+=(--body "")
    fi
    [[ "$DRAFT" -eq 1 ]] && ARGS+=(--draft)
    [[ -n "$LABELS" ]] && ARGS+=(--label "$LABELS")
    if gh "${ARGS[@]}" 2>&1 | tee "$TMP_OUT"; then
      print_or_fallback "$(extract_url "$TMP_OUT")"
    else
      # Вероятно PR уже существует — gh пишет "already exists".
      echo "(i) gh pr create упал, проверяю существующий PR..." >&2
      EXISTING="$(gh pr view "$HEAD" --json url --jq .url 2>/dev/null || gh pr view --head "$HEAD" --json url --jq .url 2>/dev/null || true)"
      if [[ -n "$EXISTING" ]]; then
        cat "$TMP_OUT" >&2 || true
        echo "PR_URL: $EXISTING"
      else
        cat "$TMP_OUT" >&2 || true
        exit 1
      fi
    fi
    ;;

  gitlab)
    command -v glab >/dev/null || { echo "Нужен glab: https://gitlab.com/gitlab-org/cli" >&2; exit 2; }
    ARGS=(mr create --title "$TITLE" --source-branch "$HEAD" --target-branch "$BASE" --yes)
    [[ -n "$BODY" ]] && ARGS+=(--description "$BODY")
    [[ "$DRAFT" -eq 1 ]] && ARGS+=(--draft)
    [[ -n "$LABELS" ]] && ARGS+=(--label "$LABELS")
    if glab "${ARGS[@]}" 2>&1 | tee "$TMP_OUT"; then
      print_or_fallback "$(extract_url "$TMP_OUT")"
    else
      echo "(i) glab mr create упал, проверяю существующий MR..." >&2
      EXISTING="$(bash "$DIR/get-pr-url.sh" --branch "$HEAD" 2>/dev/null | grep -E '^PR_URL: ' | awk '{print $2}' || true)"
      if [[ -n "$EXISTING" && "$EXISTING" != "none" ]]; then
        echo "PR_URL: $EXISTING"
      else
        exit 1
      fi
    fi
    ;;

  gitea)
    command -v tea >/dev/null || { echo "Нужен tea: https://gitea.com/gitea/tea" >&2; exit 2; }
    # Пробуем `tea pr create`, фолбэк — `tea pulls create` (старые версии).
    ARGS=(--title "$TITLE" --description "$BODY" --base "$BASE" --head "$HEAD")
    [[ "$DRAFT" -eq 1 ]] && ARGS+=(--draft)
    if (tea pr create "${ARGS[@]}" 2>&1 || tea pulls create "${ARGS[@]}" 2>&1) | tee "$TMP_OUT"; then
      print_or_fallback "$(extract_url "$TMP_OUT")"
    else
      exit 1
    fi
    ;;

  bitbucket)
    : "${BITBUCKET_WORKSPACE:?}" "${BITBUCKET_REPO_SLUG:?}" "${BITBUCKET_USERNAME:?}" "${BITBUCKET_APP_PASSWORD:?}"
    TITLE_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$TITLE")"
    DESC_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${BODY:-$TITLE}")"
    RESP_FILE="$(mktemp)"
    trap 'rm -f "$TMP_OUT" "$RESP_FILE"' EXIT
    HTTP="$(curl -s -o "$RESP_FILE" -w '%{http_code}' -X POST \
      -u "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" \
      -H "Content-Type: application/json" \
      "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests" \
      -d "{\"title\": ${TITLE_JSON}, \"description\": ${DESC_JSON}, \"source\": {\"branch\": {\"name\": \"${HEAD}\"}}, \"destination\": {\"branch\": {\"name\": \"${BASE}\"}}}" || true)"
    cat "$RESP_FILE" >&2 || true
    if [[ "$HTTP" == 2* ]]; then
      URL="$(python3 -c 'import json; d=json.load(open(sys.argv[1])); print(d.get("links",{}).get("html",{}).get("href",""))' "$RESP_FILE" 2>/dev/null || true)"
      print_or_fallback "$URL"
    else
      # 400 часто = PR уже существует — ищем его.
      echo "(i) Bitbucket вернул HTTP $HTTP, проверяю существующий PR..." >&2
      EXISTING="$(bash "$DIR/get-pr-url.sh" --branch "$HEAD" 2>/dev/null | grep -E '^PR_URL: ' | awk '{print $2}' || true)"
      if [[ -n "$EXISTING" && "$EXISTING" != "none" ]]; then
        echo "PR_URL: $EXISTING"
      else
        exit 1
      fi
    fi
    ;;

  *)
    echo "create-pr: неизвестный provider '$PROVIDER'" >&2
    exit 1
    ;;
esac
