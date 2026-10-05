---
name: nx-run-tasks
description: Helps with running tasks in an Nx workspace. USE WHEN the user wants to execute build, test, lint, serve, or run any other tasks defined in the workspace.
---

# Nx Run Tasks

Запуск задач Nx. Портирован из `.agents/skills/nx-run-tasks` в portable `.opencode` pack.
Перед запуском — сверься со скиллом `nx-workspace` (`show project --json | jq '.targets | keys'`):
запускай только существующие targets, inferred от плагинов тоже считаются.

## Run a single task

```bash
npx nx run <project>:<task>
npx nx run @backend/gateway:build
npx nx run @backend/gateway:build --configuration=production
```

Имя проекта — из `nx show projects` (в M2: `@backend/<service>`, не `@m2/`).

## Run multiple tasks

```bash
npx nx run-many -t build test lint typecheck
npx nx run-many -t test -p proj1 proj2
npx nx run-many -t test --projects=tag:api --exclude=excluded-app
npx nx run-many -t build --parallel=3
```

`-p` фильтрует по именам/globs/tags; `--exclude` исключает; `--parallel` (default 3).

## Run affected only

```bash
npx nx affected -t build test lint
npx nx affected -t test --base=main --head=HEAD
npx nx affected -t test --files=libs/mylib/src/index.ts
```

Default base — `affected.defaultBase` из `nx.json` (обычно `main`). В CI и больших
воркспейсах предпочитать `affected` полному `run-many`.

## Useful flags

Флаги работают с `run`, `run-many`, `affected`:

- `--skipNxCache` — перезапустить без кэша
- `--verbose` — стектрейсы и детали
- `--nxBail` — стоп после первой упавшей задачи
- `--configuration=<name>` — конкретная конфигурация (напр. `production`)
- `--dry-run` здесь НЕТ — это флаг генераторов, не раннера

Детали любого флага: `npx nx run-many --help`, `npx nx affected --help`.

## Правила

- Не выдумывай target: сначала `nx show project <p> --json`, потом `run`.
- Из корня consumer-репо, префикс `npx` обязателен.
- В M2 контейнеризированные проекты (`tag:container`: `admin`, `git-worker`,
  `nginx-gateway`) не собираются через `nx run` — только `pnpm build:container`.
