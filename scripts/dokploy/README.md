# dokploy — деплой compose-стеков и публикация доменов

Две стадии — два РАЗНЫХ скрипта (деплой домены не трогает, публикация
деплой не триггерит). Общий код — `lib.sh` (source, не запускать).
Требуют `curl`, `python3` (`jq` не нужен). Секреты — только из окружения.

```bash
export DOKPLOY_URL=https://<твой-докплей>
export DOKPLOY_API_KEY=...   # Dokploy → Settings → API Keys (в репо не коммитить)
```

## Стадия 1. Общий деплой — `deploy.sh`

```bash
bash .opencode/scripts/dokploy/deploy.sh --project myapp --env production
bash .opencode/scripts/dokploy/deploy.sh --project myapp --env develop --compose backend
bash .opencode/scripts/dokploy/deploy.sh --project myapp --env develop --dry-run   # без деплоя
bash .opencode/scripts/dokploy/deploy.sh --project myapp --env production --timeout 900 --poll 15 --tail 200
```

Триггерит `compose.deploy` для compose-сущности, найденной по паре
проект/окружение через `project.all` (`--compose` — если в окружении
их несколько; скрипт показывает список, а не гадает). Ждёт терминального
статуса через `deployment.allByCompose` (сравнение по `deploymentId`
до/после триггера, не по часам), при `error` печатает хвост
`deployment.readLogs`. Без destructive-действий: `compose.update/delete`
и правок env/composeFile здесь нет.

## Стадия 2. Публикация — `domains.sh` (отдельно)

```bash
bash .opencode/scripts/dokploy/domains.sh list --project myapp --env production
bash .opencode/scripts/dokploy/domains.sh add --project myapp --env production \
  --service frontend --port 3000 --host app.example.com
bash .opencode/scripts/dokploy/domains.sh add --project myapp --env production \
  --service frontend --port 3000 --host app.example.com --dry-run   # без мутации
bash .opencode/scripts/dokploy/domains.sh rm --domain-id <id>        # id — из list
```

`list` печатает таблицу `host → service:port` + готовые `https://…`
ссылки, по которым перейти. `add` публикует РОВНО ОДИН сервис
(`https` + `letsencrypt` по дефолту; `--http` — без TLS,
`--certificate-type` перекрывает). `rm` снимает публикацию по `domainId`.

ПОЛИТИКА ПУБЛИКАЦИИ: публикуется только явно указанный сервис;
internal-сервисы (пример: `opencode`) — никогда; флага `--all` НЕТ
by design (массовая публикация запрещена).

## Чеклист диагностики 404

1. Таски сервиса Running? (не Running — чинить контейнер, не домены.)
2. Healthcheck: Next отвечает `307` на `/` — это норма; проверять `r.ok`
   после редиректов, пробовать `127.0.0.1` и `localhost`, бинд `HOSTNAME=0.0.0.0`.
3. Метки роутера: `docker service inspect <stack>_<svc> | grep -i traefik`
   (для stack — раздел `deploy.labels`; авто-инжект ставит их сам).
4. Своих ручных traefik-меток в compose быть НЕ должно:
   `Skip container: both Docker and Swarm labels are defined`
   в `docker logs dokploy-traefik` = дублирование меток → 404.
5. Сервис на сети, которую видит Traefik (`dokploy-network`), иначе роутера нет.
6. `/etc/dokploy/traefik/dynamic/*.yml` для compose НЕ создаётся by design —
   отсутствие файла не баг.
7. Env: только плоские дефолты `${VAR:-literal}`; вложенные `${A:-${B}}`
   `docker stack deploy` не интерполирует (литерал утекает в контейнер).
   Проверка: `grep -rnE '\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\$\{' -- '*.yml' '*.yaml'`.

## Файлы

- `lib.sh` — общее (не запускать): `require_creds` (ключи только env),
  `api_get`/`api_post` (plain REST + `x-api-key`, поля — строго по схеме MCP),
  `redact` (вычищает ключ из вывода), `pick_compose` (composeId по
  проект/окружение через `project.all`). Грабли сессии — в шапке файла.
- `deploy.sh` — ЭТАП 1 (триггер + ожидание done/error + лог при ошибке).
- `domains.sh` — ЭТАП 2 (`list|add|rm`, политика публикации в `--help`).

## Про API (сверка)

Точные имена полей — по схеме `@dokploy/mcp`
(`https://unpkg.com/@dokploy/mcp@latest/build/generated/tools.js`):
`composeId`, `deploymentId`, `tail`, `host`, `path`, `port`, `https`,
`certificateType`, `serviceName`, `domainType`, `domainId`.
Механизм — plain REST как в `build/handler.js` MCP
(`GET /api/<proc>?k=v`, `POST /api/<proc>` JSON-телом, header `x-api-key`):
tRPC-batch (`?batch=1&input=…`) для параметризованных GET проверенно
отвечает `400 Input validation failed` и не используется.
`compose.one` отдаёт `env` целиком (там секреты) — скрипты сырой ответ
не печатают; `deploy.sh --dry-run` показывает только
`name/appName/composeStatus/composeType/sourceType`.
