---
name: link-workspace-packages
description: 'Link workspace packages in monorepos (pnpm-only portable pack). USE WHEN: (1) you just created or generated new packages and need to wire up their dependencies, (2) user imports from a sibling package and needs to add it as a dependency, (3) you get resolution errors for workspace packages (@org/*) like "cannot find module", "failed to resolve import", "TS2307", or "cannot resolve". DO NOT patch around with tsconfig paths or manual package.json edits - use pnpm workspace commands to fix actual linking.'
---

# Link Workspace Packages (pnpm-only)

Связывание workspace-пакетов. Portable pack поддерживает **только pnpm-ветку**
исходника (`.agents/skills/link-workspace-packages`): npm/yarn/bun-ветки
намеренно вырезаны — в consumer-репо единый менеджер pnpm.

## Detect Package Manager

Признак pnpm — `pnpm-lock.yaml` в корне + `packageManager: pnpm@...` в `package.json`.
Если локфайла нет или менеджер другой — стоп, спроси пользователя, не гадай командами чужого менеджера.

## Workflow

1. Определи consumer (кто импортирует) и provider (кого импортируют).
2. Добавь зависимость workspace-протоколом (ниже).
3. Проверь симлинк в `node_modules/` consumer'а и прогони затронутые targets.

```bash
# Из любого места репо, через --filter:
pnpm add @org/ui --filter @org/app --workspace

# Из директории consumer'а:
pnpm add @org/ui --workspace
```

Результат в `package.json` consumer'а:

```json
{ "dependencies": { "@org/ui": "workspace:*" } }
```

## Debug "Cannot find module" / TS2307

1. Проверь объявлен ли provider в `package.json` consumer'а.
2. Нет — добавь командой выше.
3. Прогони install из корня (`pnpm install`, никогда из подпапки — иначе stray lockfile).
4. Проверь симлинк `<consumer>/node_modules/@org/<package>`.
5. Проверь `pnpm-workspace.yaml` globs покрывают обе стороны (`apps/*`, `packages/*`).

## Notes

- pnpm: строгая изоляция, без hoisting — отсуствуют phantom deps, `workspace:*` обязателен.
- Корневой `package.json` должен иметь `"private": true` (защита от случайной публикации).
- `pnpm add -wD <pkg>` — только для root devDeps (линтеры, типы); межпакетные связи — всегда через `--filter <consumer> --workspace`.

## Запреты

- **Запрещены костыли через tsconfig `paths`** вместо реального линкования.
  `paths` не создают симлинки и маскируют отсутствующую зависимость.
- **Запрещены ручные правки `package.json`** (вписать `"workspace:*"` руками вместо
  `pnpm add --workspace`).
- Не запускать `pnpm install` из поддиректории сервиса — только из корня воркспейса.
