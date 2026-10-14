#!/usr/bin/env bash
# update-pr.sh — обновить существующий PR/MR (title/body/base/labels/ready).
# Никакого LLM. Контракт как у create-pr.sh: при успехе последняя строка
# stdout — всегда `PR_URL: <url>`. Агент обязан ретранслировать её как ссылку.
# Фатальная ошибка (нет PR, нет CLI, упал API) — ненулевой exit.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/pr/update-pr.sh [--number N | --branch B]
#       [--title "<title>"] [--body "<text>" | --body-file <file> | --json <pr.json>]
#       [--base <branch>] [--labels "a,b"] [--ready] [--dry-run]
#
# Цель: явный --number, иначе --branch (по умолчанию текущая ветка) — номер
# извлекается из ссылки (get-pr-url.sh). Нет открытого PR — exit 1
# (сначала создай через /pr --new / create-pr.sh).
# Нужно хоть одно изменение (--title/--body/--body-file/--json/--base/--labels/--ready).
#
# Стандарт body как в create-pr.sh: --json (schema/pr.schema.json +
# render-pr.py), --body / --body-file — только для исключений.
# github: gh pr edit (+ gh pr ready). gitlab: glab mr update.
# bitbucket: REST PATCH. gitea: tea не правит PR детерминированно —
# честный exit 2 с подсказкой обновить вручную.

set -euo pipefail

NUMBER=""
BRANCH=""
TITLE=""
TITLE_GIVEN=0
BODY=""
BODY_FILE=""
PR_JSON=""
BASE=""
LABELS=""
READY=0
DRY_RUN=0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: update-pr.sh [--number N | --branch B] [--title T]"
  echo "         [--body <text> | --body-file <file> | --json <pr.json>]"
  echo "         [--base <branch>] [--labels \"a,b\"] [--ready] [--dry-run]"
  echo "  Обновляет PR/MR и печатает 'PR_URL: <url>' при успехе."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --number)
      NUMBER="${2:?--number требует номер PR}"; shift 2;;
    --branch)
      BRANCH="${2:?--branch требует имя ветки}"; shift 2;;
    --title)
      TITLE="${2:?--title требует текст}"; TITLE_GIVEN=1; shift 2;;
    --body)
      BODY="${2:?--body требует текст}"; shift 2;;
    --body-file)
      BODY_FILE="${2:?--body-file требует путь}"; shift 2;;
    --json)
      PR_JSON="${2:?--json требует путь к pr.json}"; shift 2;;
    --base)
      BASE="${2:?--base требует имя ветки}"; shift 2;;
    --labels)
      LABELS="${2:?--labels требует csv}"; shift 2;;
    --ready)
      READY=1; shift;;
    --dry-run)
      DRY_RUN=1; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "update-pr: неизвестный аргумент '$1'" >&2
      usage >&2; exit 1;;
  esac
done

SET_COUNT=0
[[ -n "$BODY" ]] && SET_COUNT=$((SET_COUNT + 1))
[[ -n "$BODY_FILE" ]] && SET_COUNT=$((SET_COUNT + 1))
[[ -n "$PR_JSON" ]] && SET_COUNT=$((SET_COUNT + 1))
if [[ "$SET_COUNT" -gt 1 ]]; then
  echo "update-pr: укажи что-то одно: --body, --body-file или --json" >&2
  exit 1
fi
if [[ -n "$BODY_FILE" ]]; then
  [[ -f "$BODY_FILE" ]] || { echo "update-pr: файл не найден: $BODY_FILE" >&2; exit 1; }
  BODY="$(cat "$BODY_FILE")"
fi
if [[ -n "$PR_JSON" ]]; then
  [[ -f "$PR_JSON" ]] || { echo "update-pr: файл не найден: $PR_JSON" >&2; exit 1; }
fi

if [[ "$TITLE_GIVEN" -eq 0 && -z "$BODY" && -z "$BASE" && -z "$LABELS" && "$READY" -eq 0 && -z "$PR_JSON" ]]; then
  echo "update-pr: нечего менять — укажи --title/--body/--json/--base/--labels/--ready" >&2
  exit 1
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "update-pr: не git-репозиторий" >&2; exit 1; }

if [[ -n "$NUMBER" && -n "$BRANCH" ]]; then
  echo "update-pr: укажи что-то одно: --number или --branch" >&2
  exit 1
fi
if [[ -z "$NUMBER" ]]; then
  if [[ -z "$BRANCH" ]]; then
    BRANCH="$(git branch --show-current || true)"
    [[ -n "$BRANCH" ]] || { echo "update-pr: detached HEAD — укажи --branch или --number явно" >&2; exit 1; }
  fi
fi

# Стандартизированный body: рендерим из провалидированного JSON.
if [[ -n "$PR_JSON" ]]; then
  TMP_BODY="$(mktemp)"
  trap 'rm -f "$TMP_BODY"' EXIT
  PROVIDER_DETECT="$("$DIR/../issue-writer/detect-provider.sh")"
  python3 "$DIR/render-pr.py" "$PROVIDER_DETECT" --json "$PR_JSON" --out "$TMP_BODY"
  BODY="$(cat "$TMP_BODY")"
  rm -f "$TMP_BODY"
  trap - EXIT
  if [[ -z "$LABELS" ]]; then
    LABELS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(d.get("labels",[])))' "$PR_JSON")"
  fi
  if [[ "$TITLE_GIVEN" -eq 0 ]]; then
    TITLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["title"])' "$PR_JSON")"
  else
    JSON_TITLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["title"])' "$PR_JSON")"
    if [[ "$JSON_TITLE" != "$TITLE" ]]; then
      echo "update-pr: --title не совпадает с title в --json ('$TITLE' vs '$JSON_TITLE')" >&2
      exit 1
    fi
  fi
fi

# Номер PR: явный --number, иначе из ссылки ветки.
if [[ -z "$NUMBER" ]]; then
  URL_CANDIDATE="$(bash "$DIR/get-pr-url.sh" --branch "$BRANCH" 2>/dev/null | grep -E '^PR_URL: ' | awk '{print $2}' || true)"
  if [[ -z "$URL_CANDIDATE" || "$URL_CANDIDATE" == "none" ]]; then
    echo "update-pr: нет открытого PR для ветки '$BRANCH' — сначала создай (/pr --new)" >&2
    exit 1
  fi
  NUMBER="$(echo "$URL_CANDIDATE" | grep -oE '(pull|merge_requests|pulls)/[0-9]+' | grep -oE '[0-9]+' || true)"
  [[ -n "$NUMBER" ]] || { echo "update-pr: не извлёк номер из '$URL_CANDIDATE'" >&2; exit 1; }
  PR_URL="$URL_CANDIDATE"
else
  # URL подтянем после правки через ветку (ниже); пока заглушка.
  PR_URL=""
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "== dry-run: PR не меняю =="
  echo "number: $NUMBER"
  [[ "$TITLE_GIVEN" -eq 1 ]] && echo "title: $TITLE"
  [[ -n "$BASE" ]] && echo "base: $BASE"
  [[ -n "$LABELS" ]] && echo "labels: $LABELS"
  [[ "$READY" -eq 1 ]] && echo "ready: yes"
  if [[ -n "$BODY" ]]; then
    echo "--- BODY (preview) ---"
    echo "$BODY"
  fi
  echo "dry-run OK: выше — то, что ушло бы в PR #$NUMBER."
  exit 0
fi

PROVIDER="$("$DIR/../issue-writer/detect-provider.sh")"
echo "→ provider: $PROVIDER, PR #$NUMBER" >&2

case "$PROVIDER" in
  github)
    command -v gh >/dev/null || { echo "Нужен gh: https://cli.github.com" >&2; exit 2; }
    ARGS=(pr edit "$NUMBER")
    [[ "$TITLE_GIVEN" -eq 1 ]] && ARGS+=(--title "$TITLE")
    [[ -n "$BODY" ]] && ARGS+=(--body "$BODY")
    [[ -n "$BASE" ]] && ARGS+=(--base "$BASE")
    [[ -n "$LABELS" ]] && ARGS+=(--add-label "$LABELS")
    gh "${ARGS[@]}" >&2 || exit 1
    if [[ "$READY" -eq 1 ]]; then
      gh pr ready "$NUMBER" >&2 || exit 1
    fi
    ;;

  gitlab)
    command -v glab >/dev/null || { echo "Нужен glab: https://gitlab.com/gitlab-org/cli" >&2; exit 2; }
    ARGS=(mr update "$NUMBER")
    [[ "$TITLE_GIVEN" -eq 1 ]] && ARGS+=(--title "$TITLE")
    [[ -n "$BODY" ]] && ARGS+=(--description "$BODY")
    [[ -n "$BASE" ]] && ARGS+=(--target-branch "$BASE")
    [[ -n "$LABELS" ]] && ARGS+=(--label "$LABELS")
    [[ "$READY" -eq 1 ]] && ARGS+=(--ready)
    glab "${ARGS[@]}" >&2 || exit 1
    ;;

  gitea)
    echo "update-pr: gitea/tea не правит PR детерминированно — обнови вручную (UI или tea pulls)" >&2
    exit 2
    ;;

  bitbucket)
    : "${BITBUCKET_WORKSPACE:?}" "${BITBUCKET_REPO_SLUG:?}" "${BITBUCKET_USERNAME:?}" "${BITBUCKET_APP_PASSWORD:?}"
    PY_BODY="$(mktemp)"; trap 'rm -f "$PY_BODY"' EXIT
    python3 - "$TITLE_GIVEN" "$TITLE" "$BODY" "$BASE" <<'PY' > "$PY_BODY"
import json, sys
given, title, body, base = sys.argv[1] == "1", sys.argv[2], sys.argv[3], sys.argv[4]
payload = {}
if given:
    payload["title"] = title
if body:
    payload["description"] = body
if base:
    payload["destination"] = {"branch": {"name": base}}
print(json.dumps(payload))
PY
    trap - EXIT
    HTTP="$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
      -u "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" \
      -H "Content-Type: application/json" \
      "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests/${NUMBER}" \
      -d @"$PY_BODY" || true)"
    rm -f "$PY_BODY"
    case "$HTTP" in
      2*) ;;
      *) echo "update-pr: Bitbucket вернул HTTP $HTTP" >&2; exit 1;;
    esac
    if [[ -n "$LABELS" ]]; then
      echo "(i) Bitbucket: у PR нет labels — игнорирую --labels" >&2
    fi
    if [[ "$READY" -eq 1 ]]; then
      echo "(i) Bitbucket: флага ready нет — игнорирую --ready" >&2
    fi
    ;;

  *)
    echo "update-pr: неизвестный provider '$PROVIDER'" >&2
    exit 1
    ;;
esac

if [[ -z "$PR_URL" ]]; then
  if [[ -n "${BRANCH:-}" ]]; then
    PR_URL="$(bash "$DIR/get-pr-url.sh" --branch "$BRANCH" 2>/dev/null | grep -E '^PR_URL: ' | awk '{print $2}' || true)"
  fi
  [[ -n "$PR_URL" && "$PR_URL" != "none" ]] || { echo "update-pr: правка ушла, но ссылку получить не смог" >&2; exit 1; }
fi
echo "PR_URL: $PR_URL"
