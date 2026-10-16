# pr — создание PR и гарантированный вывод ссылки

Реализация философии пака: **агент не думает про git-ссылки, а вызывает
один скрипт**; детерминированное — в коде. Контракт обоих скриптов —
строка `PR_URL: <url>` в stdout, которую агент обязан ретранслировать
пользователю как кликабельную ссылку.

```
[контекст ветки/diff]
        │
        ▼
 агент собирает pr.json ──► validate-pr-data.py ──► render-pr.py ──► body.md
 по schema/pr.schema.json      (схема)                (шаблон, ноль LLM)
        │
        ▼
 create-pr.sh --title ... --json pr.json ──► PR_URL: https://.../pull/123
   (gh/glab/tea/REST bitbucket, как в issue-writer)

[текущая ветка] ──► get-pr-url.sh ──► PR_URL: https://... | PR_URL: none (read-only)
```

## Стандарт body (обязателен)

Агент НЕ пишет текст PR свободной формой. Формат зафиксирован шаблоном
`render-pr.py`: `## Summary` → `## Changes` → `## How to verify`
(чекбоксы) → опционально `## Notes` → футер. GitLab добавляет
`/label ~...` quick actions при наличии labels. Меняется только шаблон,
остальной пайплайн не трогаем.

## Файлы

- `schema/pr.schema.json` — контракт: `title`, `summary`, `changes[]`,
  `test_plan[]`, опционально `notes`, `labels`.
- `validate-pr-data.py` — валидация JSON (нужен `pip install jsonschema`).
- `render-pr.py` — JSON → markdown под провайдера (`github|gitlab|gitea|bitbucket`).
- `create-pr.sh` — создать PR/MR (`--title` обязателен и должен совпадать
  с `title` в `--json`; `--base/--head` по умолчанию текущая ветка →
  main/master). При успехе последняя строка stdout — всегда
  `PR_URL: <url>`. Если PR уже существует — не падает, а возвращает
  ссылку на существующий (тоже `PR_URL:`, exit 0).
  `--dry-run` — показать title/head/base + preview body, ничего не создавая.
  `--body` / `--body-file` — только для исключений, стандарт — `--json`.
- `get-pr-url.sh` — read-only: найти открытый PR/MR текущей ветки.
  Печатает `PR_URL: <url>` или `PR_URL: none`, exit 0 в обоих случаях.
  Используется после любых git-операций (`/push`, `/sync`, `/commit`),
  чтобы ссылка была даже если PR создан не агентом.
- `list-prs.sh [--filter open|closed|merged|all] [--status <lifecycle>] [--author me] [--limit N] [--json]` —
  read-only список PR/MR с живыми статусами (conflicts/checks/reviews/lifecycle —
  та же приоритетная лестница, что в `status-pr.sh`). Позволяет навести
  порядок во всех PR репозитория: что висит, что с конфликтами, что merged.
  github — per-PR `gh pr view` для checks/reviews (batch-номера `gh` не понимает),
  gitlab/gitea/bitbucket — из листинга, неизвестное честно `unknown`.
- `update-pr.sh [--number N | --branch B] [--title ...] [--body/--body-file/--json] [--base ...] [--labels ...] [--ready] [--dry-run]` —
  обновить существующий PR/MR (цель — явный номер или PR текущей ветки).
  Body-стандарт как у create (`--json`, иначе исключение); хоть одно изменение
  обязательно. github (`gh pr edit` + `gh pr ready`), gitlab (`glab mr update`),
  bitbucket (REST PATCH); gitea — честный exit 2 (tea не правит детерминированно).
  При успехе последняя строка stdout — всегда `PR_URL: <url>`.
- `status-pr.sh [--branch <name>] [--short]` — ЕДИНСТВЕННЫЙ источник правды
  о статусе PR (read-only, live-данные из CLI/API, не из памяти агента).
  Печатает `STATE`, `CONFLICTS`, `CHECKS`, `REVIEWS` и вычисленную стадию
  `LIFECYCLE`: `NO_PR` → `DRAFT` → `CONFLICTS` / `CHECKS_FAILING` /
  `CHECKS_PENDING` → `CHANGES_REQUESTED` → `APPROVED` → `MERGED`/`CLOSED`
  (приоритет именно такой: конфликты важнее чеков, чеки важнее ревью).
  `unknown` означает «не знаю» — утверждать отсутствие конфликтов можно
  только при `CONFLICTS: no`. `--short` — одна строка
  `PR_STATUS: <stage> | conflicts: … | checks: … | reviews: …` для вставки
  в вывод `/push`/`/sync` (контекст PR обновляется сам после каждой операции).
- `comments.sh [--branch <name>] [--json]` — read-only чтение замечаний
  ревьюеров (нерешённые треды первыми, затем ревью, затем общие комментарии;
  нет замечаний — `(no review comments)`, exit 0). Пара к `status-pr.sh`:
  при `CHANGES_REQUESTED` агент забирает текст замечаний этим скриптом
  и возвращает задачу исполнителю на доработку (см. `agent/auto.md` шаг 5c).
  PR принимает только человек; github — треды через GraphQL (`gh api graphql`),
  gitlab/bitbucket — best effort, gitea — честный exit 1 (читать в UI).
- Провайдер определяется через `../issue-writer/detect-provider.sh`
  (`issue_provider:` в `AGENTS.md` или автодетект по `origin`).
  CLI как в `issue-writer`: `gh` / `glab` / `tea` / REST bitbucket.

## Быстрый прогон вручную (без opencode, для проверки скриптов)

```bash
echo '{
  "title": "feat(pr): guarantee PR link output",
  "summary": "Агент гарантированно отдаёт ссылку на PR после любых git-операций.",
  "changes": ["create-pr.sh с контрактом PR_URL", "get-pr-url.sh read-only поиск"],
  "test_plan": ["bash scripts/pr/get-pr-url.sh", "bash scripts/pr/create-pr.sh --dry-run"],
  "notes": "",
  "labels": []
}' | python3 .opencode/scripts/pr/validate-pr-data.py > /tmp/pr.json

python3 .opencode/scripts/pr/render-pr.py github --json /tmp/pr.json
bash .opencode/scripts/pr/get-pr-url.sh
bash .opencode/scripts/pr/create-pr.sh --title "feat(pr): guarantee PR link output" --json /tmp/pr.json --base main --dry-run
bash .opencode/scripts/pr/update-pr.sh --number 123 --title "feat(pr): guarantee PR link output" --dry-run
bash .opencode/scripts/pr/list-prs.sh --filter open
bash .opencode/scripts/pr/list-prs.sh --status CONFLICTS --json
```
