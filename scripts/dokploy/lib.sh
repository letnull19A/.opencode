#!/usr/bin/env bash
# lib.sh — общий код dokploy-пакета (deploy.sh, domains.sh). Не запускать
# напрямую: файл source'ится, исполняемым битом НЕ наделяется.
# Требует: curl, python3 (jq может не быть — весь JSON через python3 -c).
#
# Секреты — ТОЛЬКО из окружения: DOKPLOY_URL, DOKPLOY_API_KEY.
# Никогда из аргументов/файлов/логов; ключ в чат и в файлы НЕ писать.
# Человекочитаемый вывод пропускать через redact (вычищает ключ при
# случайном отражении в телах ответов).
#
# Механизм API (сверен живьём + со схемой @dokploy/mcp — unpkg
# @dokploy/mcp@latest/build/generated/tools.js, точные имена полей обязательны):
#   GET  ${DOKPLOY_URL}/api/<proc>?<k=v...>  + header  x-api-key: ${DOKPLOY_API_KEY}
#   POST ${DOKPLOY_URL}/api/<proc>            + header  x-api-key + JSON-тело
# (как build/handler.js MCP: GET — query params, POST — JSON body.)
# tRPC-batch стиль (?batch=1&input={"0":{...}}) для параметризованных GET
# НЕ работает: compose.one отвечает 400 "Input validation failed"
# (composeId: expected string, received undefined). project.all с пустым
# входом через batch отвечал, но пакет везде использует единый plain REST.
#
# Проверенные процедуры (теги MCP: project / compose / deployment / domain):
#   project.all {}                                   → [{projectId,name,environments[]}]
#   compose.one {composeId}                          → {name,appName,env,composeFile,...}
#   compose.deploy {composeId, title?, description?} → деплой стека (мутация)
#   deployment.allByCompose {composeId}              → [{deploymentId,status,title,createdAt,...}]
#   deployment.readLogs {deploymentId, tail?}        → JSON-строка с логом
#   domain.byComposeId {composeId}                   → [{domainId,host,port,serviceName,...}]
#   domain.create {host,path,port,https,certificateType,composeId,serviceName,domainType}
#   domain.delete {domainId}
#   domain.update {domainId, host, ...}              (пакет не использует)
#
# Грабли сессии — зафиксированы, не повторять:
#   1. `docker stack deploy` НЕ интерполирует вложенные дефолты ${A:-${B}} —
#      литерал ${B} утекает в контейнер (сервис падает, напр.
#      "must be a numeric port"). Плюс stack deploy НЕ читает env-файл:
#      значения с ${...} в Dokploy-env раскрывать заранее
#      (плоские дефолты в compose + конкретные значения в env).
#      Самопроверка: grep -rnE '\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\$\{' -- '*.yml' '*.yaml'
#   2. /etc/dokploy/traefik/dynamic/*.yml для compose НЕ создаётся by design
#      (роутинг идёт через docker/swarm-провайдер по инжектированным лейблам)
#      — отсутствие файла НЕ баг, файловый провайдер ни при чём.
#   3. Ручные traefik-метки в compose + авто-инжект Dokploy =
#      "Skip container: both Docker and Swarm labels are defined" → 404.
#      Свои traefik-метки не дублировать.
#   4. Для stack нужны deploy.labels (авто-инжект их ставит сам); сервис
#      обязан быть на сети, которую видит Traefik (dokploy-network),
#      иначе роутера нет (дефолтная 404).
#   5. Healthcheck frontend: Next отвечает 307 на "/" — проверять r.ok после
#      редиректов + пробовать 127.0.0.1 и localhost (loopback mismatch);
#      бинд — HOSTNAME=0.0.0.0, иначе контейнер слушает только hostname.
#   6. compose.one отдаёт env целиком (там секреты!) — сырой ответ никогда
#      не печатать; deploy.sh --dry-run показывает только
#      name/appName/composeStatus/sourceType.

set -euo pipefail

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "dokploy: нужен '$1' (не найден в PATH)" >&2; exit 1; }
}
need_cmd curl
need_cmd python3

DOKPLOY_URL="${DOKPLOY_URL:-}"
DOKPLOY_URL="${DOKPLOY_URL%/}" # без хвостового слеша

require_creds() {
  [[ -n "${DOKPLOY_URL:-}" ]] || { echo "dokploy: нет DOKPLOY_URL — задай: export DOKPLOY_URL=https://<твой-докплей>" >&2; exit 1; }
  [[ -n "${DOKPLOY_API_KEY:-}" ]] || { echo "dokploy: нет DOKPLOY_API_KEY — задай: export DOKPLOY_API_KEY=... (Dokploy → Settings → API Keys). Ключ только в env, в репозиторий не коммитить." >&2; exit 1; }
}

# redact — вычистить API-ключ из потока (на случай отражения в ответах).
redact() {
  python3 -c 'import sys, os; k = os.environ.get("DOKPLOY_API_KEY", ""); s = sys.stdin.read(); sys.stdout.write(s.replace(k, "***") if k else s)'
}

# api_get <proc> [k=v ...] — GET /api/<proc>?k=v + x-api-key. Только чтение.
api_get() {
  local proc="$1"; shift
  # -G обязателен: без него --data-urlencode шлёт POST вместо GET
  # (POST-маршрута у read-процедур нет → 404).
  local -a args=(-fsSL -G -H "x-api-key: ${DOKPLOY_API_KEY}")
  local kv
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  curl "${args[@]}" "${DOKPLOY_URL}/api/${proc}" \
    || { echo "dokploy: API GET ${proc} упал (проверь DOKPLOY_URL, сеть и ключ)" >&2; return 1; }
}

# api_post <proc> <json> — POST /api/<proc> JSON-телом + x-api-key. Мутация!
api_post() {
  local proc="$1" json="$2"
  curl -fsSL -X POST "${DOKPLOY_URL}/api/${proc}" \
    -H "x-api-key: ${DOKPLOY_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$json" \
    || { echo "dokploy: API POST ${proc} упал (проверь DOKPLOY_URL, сеть, ключ и тело запроса)" >&2; return 1; }
}

# pick_compose <project> <env> [compose-name] — печатает composeId в stdout,
# пояснения — в stderr. Точное совпадение имён: проект → окружение → compose.
# Без compose-name: ровно один compose в окружении — берётся он, иначе
# список доступных + exit 1 (агент показывает список, а не гадает).
pick_compose() {
  local project="$1" env="$2" want="${3:-}"
  api_get project.all | python3 -c '
import json, sys
project, env, want = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.load(sys.stdin)
except Exception as e:
    print("dokploy: project.all: не JSON (%s)" % e, file=sys.stderr); sys.exit(1)
projs = data if isinstance(data, list) else data.get("projects", [])
hit = [p for p in projs if p.get("name") == project]
if not hit:
    print("dokploy: проект \"%s\" не найден. Доступные:" % project, file=sys.stderr)
    for p in projs:
        print("  - %s" % p.get("name"), file=sys.stderr)
    sys.exit(1)
envs = hit[0].get("environments") or []
match = [x for x in envs if x.get("name") == env]
if not match:
    print("dokploy: окружение \"%s\" в проекте \"%s\" не найдено. Доступные:" % (env, project), file=sys.stderr)
    for x in envs:
        print("  - %s" % x.get("name"), file=sys.stderr)
    sys.exit(1)
composes = match[0].get("compose") or match[0].get("composes") or []
if want:
    sel = [x for x in composes if x.get("name") == want]
    if not sel:
        print("dokploy: compose \"%s\" нет в %s/%s. Доступные:" % (want, project, env), file=sys.stderr)
        for x in composes:
            print("  - %s (appName=%s status=%s)" % (x.get("name"), x.get("appName"), x.get("composeStatus")), file=sys.stderr)
        sys.exit(1)
    sel = sel[0]
else:
    if len(composes) == 0:
        print("dokploy: в %s/%s нет compose-сущностей" % (project, env), file=sys.stderr); sys.exit(1)
    if len(composes) > 1:
        print("dokploy: в %s/%s несколько compose — уточни --compose. Доступные:" % (project, env), file=sys.stderr)
        for x in composes:
            print("  - %s (appName=%s status=%s)" % (x.get("name"), x.get("appName"), x.get("composeStatus")), file=sys.stderr)
        sys.exit(1)
    sel = composes[0]
extra = " appName=%s" % sel.get("appName") if sel.get("appName") else ""
print("dokploy: compose \"%s\"%s status=%s" % (sel.get("name"), extra, sel.get("composeStatus")), file=sys.stderr)
print(sel.get("composeId"))
' "$project" "$env" "$want"
}
