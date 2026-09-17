---
description: Диагностика неполадок — разведка (Dokploy, деплои, workflows) → пошаговое следствие к виновнику
agent: diagnostics
---

Ты выполняешься как агент `diagnostics` (только чтение). Найди виновника инцидента.

Контекст: `$ARGUMENTS` (напр. "не задеплоились изменения на dev после пуша", "упал workflow test.yml", "сервис не отвечает на PREVIEW_URL").

Действуй строго по `skills/diagnostics/SKILL.md`: Фаза 1 разведка (git + `ci/workflows.sh status --json` + `mcp.dokploy` + `read` workflows) → Фаза 2 следствие шаг за шагом (Git → Workflows → Dokploy → Traefik, фиксируя вердикт) → отчёт `## Диагноз` + `failedSteps`/`logExcerpt` по степени подробности (кратко без логов, детально с `logs --run <id> --failed-only`).

Правила: только чтение, не чини, не выдумывай id, на `no_gh`/`no_dokploy` — подскажи и стоп.
