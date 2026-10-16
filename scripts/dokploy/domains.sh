#!/usr/bin/env bash
# domains.sh — ЭТАП 2, публикация: домены поверх compose-стека. ОТДЕЛЬНО
# от deploy.sh (деплой домены не трогает, публикация деплой не триггерит).
#
# Подкоманды:
#   list  — таблица host → service:port (+ https-ссылки, по которым перейти)
#   add   — опубликовать ОДИН сервис (https+letsencrypt по дефолту)
#   rm    — снять публикацию по domainId
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/dokploy/domains.sh list --project <n> --env <e> [--compose <c>]
#   bash .opencode/scripts/dokploy/domains.sh add --project <n> --env <e> [--compose <c>] \
#       --service <name> --port <n> --host <h> [--path /] [--http] [--certificate-type <t>] [--dry-run]
#   bash .opencode/scripts/dokploy/domains.sh rm --domain-id <id> [--dry-run]
#
# ПОЛИТИКА ПУБЛИКАЦИИ (намеренно жёсткая):
#   - публикуется ТОЛЬКО явно указанный сервис (add — ровно один за вызов);
#   - internal-сервисы (пример: opencode) НЕ публикуются никогда;
#   - флага --all НЕТ by design (массовая публикация запрещена).
#
# Коды выхода: 0 — ок; 1 — плохие аргументы / API-ошибка.

set -euo pipefail

HERE="$(dirname "$0")"
# shellcheck disable=SC1091
. "$HERE/lib.sh"

usage() {
  echo "Usage:"
  echo "  domains.sh list --project <name> --env <develop|production> [--compose <name>]"
  echo "  domains.sh add --project <name> --env <e> [--compose <c>] --service <name> --port <n> --host <h> [--path /] [--http] [--certificate-type letsencrypt|none|custom] [--dry-run]"
  echo "  domains.sh rm --domain-id <id> [--dry-run]"
  echo "Политика: публикуется только явно указанный сервис; internal-сервисы"
  echo "(пример: opencode) — никогда; --all нет by design."
}

CMD="${1:-}"
[[ -n "$CMD" ]] || { usage >&2; exit 1; }
case "$CMD" in
  -h|--help) usage; exit 0 ;;
  list|add|rm) shift ;;
  *) echo "dokploy: подкоманда '$CMD' — только list|add|rm" >&2; usage >&2; exit 1 ;;
esac

PROJECT=""; ENV=""; COMPOSE=""
SERVICE=""; PORT=""; HOST=""; DPATH="/"; HTTPS=1; CERT=""; CERT_GIVEN=0; DOMAIN_ID=""; DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:?--project требует имя проекта}"; shift 2 ;;
    --env) ENV="${2:?--env требует имя окружения}"; shift 2 ;;
    --compose) COMPOSE="${2:?--compose требует имя compose-сущности}"; shift 2 ;;
    --service) SERVICE="${2:?--service требует имя сервиса}"; shift 2 ;;
    --port) PORT="${2:?--port требует номер порта}"; shift 2 ;;
    --host) HOST="${2:?--host требует домен}"; shift 2 ;;
    --path) DPATH="${2:?--path требует путь}"; shift 2 ;;
    --http) HTTPS=0; shift ;;
    --certificate-type) CERT="${2:?--certificate-type требует letsencrypt|none|custom}"; CERT_GIVEN=1; shift 2 ;;
    --domain-id) DOMAIN_ID="${2:?--domain-id требует id домена}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "dokploy: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

case "$CMD" in
  list)
    [[ -n "$PROJECT" ]] || { echo "dokploy: list: укажи --project" >&2; usage >&2; exit 1; }
    [[ -n "$ENV" ]] || { echo "dokploy: list: укажи --env" >&2; usage >&2; exit 1; }
    require_creds
    COMPOSE_ID="$(pick_compose "$PROJECT" "$ENV" "$COMPOSE")" || exit 1
    api_get domain.byComposeId "composeId=${COMPOSE_ID}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("dokploy: domain.byComposeId: не JSON (%s)" % e, file=sys.stderr); sys.exit(1)
rows = d if isinstance(d, list) else []
if not rows:
    print("Доменов нет — публикация не настроена. Добавление: domains.sh add ... (см. --help).")
    sys.exit(0)
w = max([len(r.get("host", "")) for r in rows] + [len("HOST")])
fmt = "%-" + str(w) + "s %-16s %-6s %-6s %-10s %-4s"
print(fmt % ("HOST", "SERVICE", "PORT", "HTTPS", "CERT", "ON"))
for r in sorted(rows, key=lambda x: x.get("host", "")):
    print(fmt % (
        r.get("host", ""), r.get("serviceName", ""), r.get("port", ""),
        "yes" if r.get("https") else "no",
        r.get("certificateType", ""), "yes" if r.get("enabled", True) else "no"))
print("")
for r in sorted(rows, key=lambda x: x.get("host", "")):
    if r.get("enabled", True):
        scheme = "https" if r.get("https") else "http"
        print("%s://%s" % (scheme, r.get("host", "")))
' | redact
    ;;

  add)
    [[ -n "$PROJECT" ]] || { echo "dokploy: add: укажи --project" >&2; usage >&2; exit 1; }
    [[ -n "$ENV" ]] || { echo "dokploy: add: укажи --env" >&2; usage >&2; exit 1; }
    [[ -n "$SERVICE" ]] || { echo "dokploy: add: укажи --service <name> (публикуется ровно один сервис)" >&2; usage >&2; exit 1; }
    [[ -n "$PORT" ]] || { echo "dokploy: add: укажи --port <n> (внутренний порт контейнера)" >&2; usage >&2; exit 1; }
    [[ -n "$HOST" ]] || { echo "dokploy: add: укажи --host <h>" >&2; usage >&2; exit 1; }
    [[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$PORT" -ge 1 ]] && [[ "$PORT" -le 65535 ]] \
      || { echo "dokploy: add: --port: только 1..65535, получено '$PORT'" >&2; exit 1; }
    if [[ "$CERT_GIVEN" -eq 1 ]]; then
      [[ "$CERT" == "letsencrypt" || "$CERT" == "none" || "$CERT" == "custom" ]] \
        || { echo "dokploy: add: --certificate-type: только letsencrypt|none|custom" >&2; exit 1; }
    else
      if [[ "$HTTPS" -eq 1 ]]; then CERT="letsencrypt"; else CERT="none"; fi
    fi
    require_creds
    COMPOSE_ID="$(pick_compose "$PROJECT" "$ENV" "$COMPOSE")" || exit 1
    CREATE_JSON="$(python3 -c 'import json, sys; print(json.dumps({
        "host": sys.argv[1], "path": sys.argv[2], "port": int(sys.argv[3]),
        "https": sys.argv[4] == "1", "certificateType": sys.argv[5],
        "composeId": sys.argv[6], "serviceName": sys.argv[7], "domainType": "compose"}))' \
      "$HOST" "$DPATH" "$PORT" "$HTTPS" "$CERT" "$COMPOSE_ID" "$SERVICE")"
    if [[ "$DRY" -eq 1 ]]; then
      echo "== dry-run: domain.create НЕ вызван =="
      printf '%s\n' "$CREATE_JSON" | python3 -m json.tool
      echo "dry-run OK: выше — тело, ушедшее бы в domain.create."
      exit 0
    fi
    echo "== публикую $HOST → $SERVICE:$PORT (https=$HTTPS cert=$CERT) =="
    api_post domain.create "$CREATE_JSON" | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception as e:
    print("dokploy: domain.create: не JSON (%s)" % e, file=sys.stderr); sys.exit(1)
print("domainId: %s" % r.get("domainId", "?"))
print("host: %s -> %s:%s" % (r.get("host"), r.get("serviceName"), r.get("port")))
' | redact
    if [[ "$HTTPS" -eq 1 ]]; then echo "Открыть: https://$HOST"; else echo "Открыть: http://$HOST"; fi
    ;;

  rm)
    [[ -n "$DOMAIN_ID" ]] || { echo "dokploy: rm: укажи --domain-id <id> (см. domains.sh list)" >&2; usage >&2; exit 1; }
    require_creds
    RM_JSON="$(python3 -c 'import json, sys; print(json.dumps({"domainId": sys.argv[1]}))' "$DOMAIN_ID")"
    if [[ "$DRY" -eq 1 ]]; then
      echo "== dry-run: domain.delete НЕ вызван =="
      printf '%s\n' "$RM_JSON" | python3 -m json.tool
      echo "dry-run OK: выше — тело, ушедшее бы в domain.delete."
      exit 0
    fi
    echo "== снимаю публикацию ${DOMAIN_ID} =="
    api_post domain.delete "$RM_JSON" | redact
    echo "Готово: ${DOMAIN_ID} удалён. Проверь: domains.sh list --project <n> --env <e>"
    ;;
esac
