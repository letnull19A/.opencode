---
name: diagnostics
description: Диагностика неполадок — разведка (git, GitHub Actions, Dokploy) → пошаговое следствие к виновнику. Используй когда не задеплоилось, упал workflow, сервис не отвечает, нужен отчёт кто виноват.
---

Ты умеешь находить виновника, не чиня. Все команды — из корня репо, только чтение.

## Предпосылки

- `gh` CLI для workflows (`gh auth login` или `GITHUB_TOKEN` env). Нет `gh` — верни `{"error":"no_gh"}` и подсказку, не гадай.
- `DOKPLOY_URL` + `DOKPLOY_API_KEY` env для `mcp.dokploy` (Dokploy Settings → API Keys). Нет — подскажи и стоп.
- `git` — `status/diff/log` разрешены.

## Фаза 1 — Разведка (собери всё, до выводов)

Пачками где можно, без мутаций:

1. **Git:** `git status --porcelain`, `git log --oneline -10`, `git diff --stat HEAD`, `git branch --show-current`
2. **Workflows (выбери степень):**
   - Кратко (какой степ упал): `bash .opencode/scripts/ci/workflows.sh status --branch <branch> --limit 5 --json`
   - Детально (логи упавших): `bash .opencode/scripts/ci/workflows.sh logs --run <id> --failed-only --json`
   - Фильтр: `--workflow <file>` (напр. `docker-build-all.yml`)
3. **Dokploy (MCP, не bash):** `dokploy_project_all` → `dokploy_application_one` / `dokploy_application_search` / `dokploy_compose_one` → `dokploy_application_readAppMonitoring` / `readLogs` / `readTraefikConfig`
4. **Конфиги:** `read` `.github/workflows/*.yml`, `docker-compose.yml`, `server/Dockerfile`

Не делай выводов пока не соберёшь 4 блока.

## Фаза 2 — Следствие (шаг за шагом)

Иди по цепочке, фиксируя вердикт:

1. **Git не ушёл?** `git log origin/dev..HEAD`, `bash .opencode/scripts/sync/run.sh --dry-run` — `ahead 0` + чистый `status` но нет нового рана → пуш не ушёл.
2. **Workflow не триггернулся / упал?** `status` → нет рана → `on: push` сломан; есть `conclusion: failure` → `failedSteps[]` → `logs --run <id> --failed-only` → точный степ.
3. **Workflow прошёл, но Dokploy не деплоил?** `jobs` → нет `deploy` → `docker-build-all.yml` `needs/if` сломан; есть `deploy` `success` но `vars.DOKPLOY_WEBHOOKS` пустой → `curl` не ушёл.
4. **Dokploy хук дошёл, но деплой упал?** `application_one` `deployment` `failed` + `readLogs` tail 50 + `readTraefikConfig`.
5. **Деплой прошёл, но трафик не дошёл?** `readTraefikConfig` vs `docker-compose.yml` порт/домен mismatch.

На каждом шаге: `Шаг N: <гипотеза> → <команда> → <вывод> → вердикт`.

## Вывод

```markdown
## Диагноз: <кто виновник>
**Цепочка:** Git → Workflows → Dokploy → Traefik — где оборвалось
**Доказательства:** git log, workflows status failedSteps, gh log excerpt, dokploy logs
**Виновник:** workflows/dokploy/git/traefik — файл/степ/переменная
**Фикс:** 1–3 шага + как проверить (workflows status / dokploy readLogs)
```

Если нужен кратко — только `Диагноз` + `failedSteps` без `logExcerpt`.

## Правила

- Только чтение: `edit: deny`, `bash` только `ci/*`/`sync/*`/`git ...`, `dokploy` только MCP.
- Не чини — только находишь. `git push` только `--dry-run`.
- Не выдумывай `id`/`url` — только из вывода скриптов/MCP.
