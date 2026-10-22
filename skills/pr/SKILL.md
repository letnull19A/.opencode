---
name: pr
description: Single source of truth for pull requests via .opencode/scripts/pr/* (status/get-url/list/comments/update/create). Use for ANY PR question or mutation — raw gh/glab/tea/curl to PR APIs is deny-listed, memory is not a source.
---

PR URL агент гарантирует кликабельной строкой `PR_URL: <url>`. Тело PR свободной формой НЕ пишешь — только JSON по `scripts/pr/schema/pr.schema.json` → `validate-pr-data.py` → `render-pr.py` → `create-pr.sh` (скрипт сам рендерит `Summary` → `Changes` → `How to verify` → `Notes`).

## Когда вызывать

- Перед ЛЮБЫМ ответом о статусе PR: `status-pr.sh` (конфликты/checks/reviews/lifecycle). `CONFLICTS: unknown` = «не знаю», не «конфликтов нет».
- После `/push`/`/sync`/`/commit` и при любом упоминании PR: `get-pr-url.sh` → ретрансляция `PR_URL:` (или `PR_URL: none` + как создать).
- Мерж PR — НИКОГДА (только человек в UI/CLI). Просят «замержи» — отдаёшь `PR_URL:` + свежий `status-pr.sh` + команду для ручного мержа.

## Рецепты (read-only сначала)

```bash
bash .opencode/scripts/pr/status-pr.sh --branch <name>
```

```bash
bash .opencode/scripts/pr/get-pr-url.sh --branch <name>
```

```bash
bash .opencode/scripts/pr/list-prs.sh --filter open --json
```

```bash
bash .opencode/scripts/pr/comments.sh --branch <name>
```

```bash
bash .opencode/scripts/pr/update-pr.sh --branch <name> --title "<t>"
```

```bash
echo '<json>' | python3 .opencode/scripts/pr/validate-pr-data.py > /tmp/opencode/pr.json
```

```bash
bash .opencode/scripts/pr/create-pr.sh --title "<t>" --json /tmp/opencode/pr.json --base <base>
```

- `status-pr.sh` — ЕДИНСТВЕННЫЙ источник правды; `comments.sh` — нерешённые треды первыми (их чинить обязательно).
- Детали форматов — `scripts/pr/README.md` + `scripts/pr/schema/pr.schema.json`.

## Правила

- Сырые `gh pr view/list/create/merge`, `glab mr`, `tea`, `curl` к `*pulls*/merge*` — неснимаемый `deny`. `gh api .../merge` приравнивается к нарушению.
- `CHANGES_REQUESTED`/`CONFLICTS`/`CHECKS_FAILING` — задача на доработку, не в `done`: забираешь замечания и возвращаешь карточку тому же исполнителю.
- Скилл прав не даёт: нет `scripts/pr/*` в allowlist — просишь родителя/человека.
