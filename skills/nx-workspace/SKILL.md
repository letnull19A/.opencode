---
name: nx-workspace
description: Explore and understand Nx workspaces. USE WHEN answering questions about the workspace, projects, or tasks. ALSO USE WHEN an nx command fails or you need to check available targets/configuration before running a task. EXAMPLES: 'What projects are in this workspace?', 'How is project X configured?', 'What depends on library Y?', 'What targets can I run?', 'Cannot find configuration for task', 'debug nx task failure'.
---

# Nx Workspace Exploration

Read-only разведка Nx-воркспейса. Никаких мутаций — только `show/graph/cat/jq`.
Портирован из `.agents/skills/nx-workspace` в portable `.opencode` pack.

## Listing Projects

```bash
npx nx show projects
npx nx show projects --json
npx nx show projects --projects "apps/*"
npx nx show projects --projects "tag:publishable"
npx nx show projects --withTarget build
npx nx show projects --type app
npx nx show projects --type lib
npx nx show projects --affected --json
```

Фильтры `-p/--projects`: имена, globs, `tag:name`, директории, негация `!name`.
Фильтры работают и в `run-many/affected/show projects`.

Программно (не считать глазами):

```bash
npx nx show projects --json | jq 'length'
npx nx show projects --json | jq '.[] | select(startswith("shared-"))'
npx nx show projects --affected --json | jq '.'
```

## Project Configuration

```bash
npx nx show project <name> --json | jq '.targets'
npx nx show project <name> --json | jq '.targets | keys'
npx nx show project <name> --json | jq '.targets.build'
npx nx show project <name> --json | jq '{name, root, sourceRoot, projectType, tags}'
```

**Запрет: НЕ читать `project.json` напрямую** — там лишь частичная конфигурация.
Полный резолв (включая inferred targets от плагинов) — только `nx show project --json`.
Схема: `node_modules/nx/schemas/project-schema.json`.

## Workspace Configuration

`nx.json` — читать напрямую:

```bash
cat nx.json | jq '.targetDefaults'
cat nx.json | jq '.namedInputs'
cat nx.json | jq '.plugins'
cat nx.json | jq '.generators'
```

Ключевые секции: `targetDefaults`, `namedInputs`, `plugins`, `generators`, `affected.defaultBase`.
Схема: `node_modules/nx/schemas/nx-schema.json`.

## Project Graph

```bash
npx nx graph --print | jq '.graph.nodes | keys'
npx nx graph --print | jq '.graph.dependencies["my-app"]'
npx nx graph --print | jq '.graph.dependencies | to_entries[] | select(.value[].target == "shared-ui") | .key'
```

Визуальный граф (`npx nx graph` без `--print`) — только по просьбе пользователя,
в headless-окружении использовать только `--print`.

## Troubleshooting

```bash
# "Cannot find configuration for task X:target"
npx nx show project X --json | jq '.targets | keys'
npx nx show projects --withTarget <target>

# "The workspace is out of sync" / stale cache
npx nx sync
npx nx reset  # если sync не помог
```

## Правила

- Только чтение: `show/graph/sync --help`, `cat nx.json`, `jq`. Никаких `generate/add/run`.
- Всегда `--json` + `jq` для программных ответов, не парсить глазами.
- Префикс `npx` обязателен (`npx nx ...`), глобальный `nx` не предполагать.
- Запуск из корня consumer-репо (где лежит `.opencode/`).
