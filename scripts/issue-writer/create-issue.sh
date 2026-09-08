#!/usr/bin/env bash
# Шаг 4 пайплайна: создать issue у провайдера через готовый CLI (не свой велосипед).
# Никакого LLM. Требует: title файл, body(markdown) файл, provider, опционально labels.
#
# Использование:
#   scripts/create-issue.sh <provider> <title> <body_file> [labels_csv]
#
# CLI-зависимости (нужно поставить заранее, это официальные/community инструменты):
#   github   -> gh        (https://cli.github.com)
#   gitlab   -> glab      (https://gitlab.com/gitlab-org/cli)
#   gitea    -> tea       (https://gitea.com/gitea/tea)
#   bitbucket -> нет вменяемого официального CLI -> идём через REST API (curl)
#               нужны env: BITBUCKET_WORKSPACE, BITBUCKET_REPO_SLUG,
#                          BITBUCKET_USERNAME, BITBUCKET_APP_PASSWORD

set -euo pipefail

PROVIDER="${1:?provider required: github|gitlab|gitea|bitbucket}"
TITLE="${2:?title required}"
BODY_FILE="${3:?path to markdown body file required}"
LABELS_CSV="${4:-}"

[[ -f "$BODY_FILE" ]] || { echo "create-issue: файл body не найден: $BODY_FILE" >&2; exit 1; }

case "$PROVIDER" in
  github)
    command -v gh >/dev/null || { echo "Нужен gh: https://cli.github.com" >&2; exit 2; }
    ARGS=(issue create --title "$TITLE" --body-file "$BODY_FILE")
    [[ -n "$LABELS_CSV" ]] && ARGS+=(--label "$LABELS_CSV")
    gh "${ARGS[@]}"
    ;;

  gitlab)
    command -v glab >/dev/null || { echo "Нужен glab: https://gitlab.com/gitlab-org/cli" >&2; exit 2; }
    ARGS=(issue create --title "$TITLE" --description "$(cat "$BODY_FILE")")
    [[ -n "$LABELS_CSV" ]] && ARGS+=(--label "$LABELS_CSV")
    glab "${ARGS[@]}"
    ;;

  gitea)
    command -v tea >/dev/null || { echo "Нужен tea: https://gitea.com/gitea/tea" >&2; exit 2; }
    ARGS=(issue create --title "$TITLE" --description "$(cat "$BODY_FILE")")
    [[ -n "$LABELS_CSV" ]] && ARGS+=(--labels "$LABELS_CSV")
    tea "${ARGS[@]}"
    ;;

  bitbucket)
    : "${BITBUCKET_WORKSPACE:?}" "${BITBUCKET_REPO_SLUG:?}" "${BITBUCKET_USERNAME:?}" "${BITBUCKET_APP_PASSWORD:?}"
    BODY_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < "$BODY_FILE")"
    curl -sf -X POST \
      -u "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" \
      -H "Content-Type: application/json" \
      "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/issues" \
      -d "{\"title\": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$TITLE"), \"content\": {\"raw\": ${BODY_JSON}}}"
    ;;

  *)
    echo "create-issue: неизвестный provider '$PROVIDER'" >&2
    exit 1
    ;;
esac
