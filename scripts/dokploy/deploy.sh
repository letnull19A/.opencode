#!/usr/bin/env bash
# deploy.sh — ЭТАП 1, общий деплой compose-стека в Dokploy.
#
# Делает ровно одно: триггерит compose.deploy для compose-сущности,
# найденной по паре проект/окружение (см. pick_compose в lib.sh),
# ждёт терминального статуса (done/error) через deployment.allByCompose
# и показывает хвост лога при ошибке. Без destructive-действий:
# compose.update/delete, правки env/composeFile здесь НЕТ и не будет.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/dokploy/deploy.sh --project <name> --env <develop|production>
#       [--compose <name>] [--timeout <s>] [--poll <s>] [--tail <n>] [--dry-run]
#
#   --compose обязателен, если в окружении больше одного compose
#   (скрипт покажет список, а не угадает). --dry-run резолвит compose
#   и показывает сводку compose.one БЕЗ деплоя (поле env никогда не печатается —
#   там секреты). Публикация доменов — отдельно: domains.sh (ЭТАП 2).
#
# Коды выхода: 0 — done; 1 — ошибка деплоя/таймаут/плохие аргументы.

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

PROJECT=""; ENV=""; COMPOSE=""; TIMEOUT=600; POLL=10; TAIL=100; DRY=0

usage() {
  echo "Usage: deploy.sh --project <name> --env <develop|production> [--compose <name>] [--timeout <s>] [--poll <s>] [--tail <n>] [--dry-run]"
  echo "  Триггерит compose.deploy и ждёт done/error (poll deployment.allByCompose)."
  echo "  Без destructive-действий. Домены — отдельно: domains.sh list|add|rm."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:?--project требует имя проекта}"; shift 2 ;;
    --env) ENV="${2:?--env требует имя окружения}"; shift 2 ;;
    --compose) COMPOSE="${2:?--compose требует имя compose-сущности}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout требует секунды}"; shift 2 ;;
    --poll) POLL="${2:?--poll требует секунды}"; shift 2 ;;
    --tail) TAIL="${2:?--tail требует число строк}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "dokploy: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "dokploy: укажи --project <name>" >&2; usage >&2; exit 1; }
[[ -n "$ENV" ]] || { echo "dokploy: укажи --env <develop|production>" >&2; usage >&2; exit 1; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [[ "$TIMEOUT" -gt 0 ]] || { echo "dokploy: --timeout: только положительное число" >&2; exit 1; }
[[ "$POLL" =~ ^[0-9]+$ ]] && [[ "$POLL" -gt 0 ]] || { echo "dokploy: --poll: только положительное число" >&2; exit 1; }
[[ "$TAIL" =~ ^[0-9]+$ ]] && [[ "$TAIL" -gt 0 ]] || { echo "dokploy: --tail: только положительное число" >&2; exit 1; }

require_creds

COMPOSE_ID="$(pick_compose "$PROJECT" "$ENV" "$COMPOSE")" || exit 1

if [[ "$DRY" -eq 1 ]]; then
  echo "== dry-run: деплоя нет, только сводка =="
  api_get compose.one "composeId=${COMPOSE_ID}" | python3 -c '
import json, sys
c = json.load(sys.stdin)
for k in ("name", "appName", "composeStatus", "composeType", "sourceType"):
    print("%s: %s" % (k, c.get(k)))
print("НИКОГДА не печатать поле env целиком — там секреты.")
'
  echo "dry-run OK: выше — то, что уехало бы в compose.deploy."
  exit 0
fi

# Новейший деплой ДО триггера — чтобы ждать именно наш (сравнение по id,
# а не по часам: часы агента и сервера могут расходиться).
BEFORE_ID="$(api_get deployment.allByCompose "composeId=${COMPOSE_ID}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
d = sorted(d, key=lambda r: r.get("createdAt", ""))
print(d[-1].get("deploymentId", "") if d else "")
')"

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DEPLOY_JSON="$(python3 -c 'import json, sys; print(json.dumps({"composeId": sys.argv[1], "title": sys.argv[2]}))' \
  "$COMPOSE_ID" "deploy.sh $PROJECT/$ENV $STAMP")"

echo "== триггерю compose.deploy ($PROJECT/$ENV) =="
api_post compose.deploy "$DEPLOY_JSON" | redact
echo "(i) Ответ выше — подтверждение приёма; статус — в poll ниже."

START="$(date +%s)"
while :; do
  NOW="$(date +%s)"
  if (( NOW - START >= TIMEOUT )); then
    echo "deploy: таймаут ${TIMEOUT}s — деплой не дошёл до done/error." >&2
    echo "Смотри deployments вручную (deployment.allByCompose) или повтори с --timeout больше." >&2
    exit 1
  fi
  STATE="$(api_get deployment.allByCompose "composeId=${COMPOSE_ID}" | python3 -c '
import json, sys
before = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    d = []
d = sorted(d, key=lambda r: r.get("createdAt", ""))
new = [r for r in d if r.get("deploymentId") != before]
if not new:
    print("WAIT")
else:
    cur = new[-1]
    print("%s\t%s\t%s" % (cur.get("status", "?"), cur.get("deploymentId", ""), (cur.get("title") or "").splitlines()[0] if cur.get("title") else ""))
' "$BEFORE_ID")"
  if [[ "$STATE" == "WAIT" ]]; then
    echo "deploy: новый деплой пока не виден, жду ${POLL}s..."
    sleep "$POLL"
    continue
  fi
  STATUS="${STATE%%$'\t'*}"; REST="${STATE#*$'\t'}"
  NEW_ID="${REST%%$'\t'*}"; TITLE="${REST#*$'\t'}"
  if [[ "$STATUS" == "done" ]]; then
    echo "deploy: done (deployment ${NEW_ID}, ${TITLE})."
    echo "Домены: bash .opencode/scripts/dokploy/domains.sh list --project \"$PROJECT\" --env \"$ENV\"${COMPOSE:+ --compose \"$COMPOSE\"}"
    exit 0
  fi
  if [[ "$STATUS" == "error" ]]; then
    echo "deploy: error (deployment ${NEW_ID}, ${TITLE}). Хвост лога:" >&2
    api_get deployment.readLogs "deploymentId=${NEW_ID}" "tail=${TAIL}" \
      | python3 -c 'import json, sys; print(json.load(sys.stdin))' | redact >&2
    exit 1
  fi
  echo "deploy: статус '${STATUS}' (deployment ${NEW_ID}) — жду ${POLL}s..."
  sleep "$POLL"
done
