---
name: nx-generate
description: Generate code using nx generators. INVOKE IMMEDIATELY when user mentions scaffolding, setup, structure, creating apps/libs, or setting up project structure. Trigger words - scaffold, setup, create a new app, create a new lib, project structure, generate, add a new project. ALWAYS use this BEFORE calling nx_docs or exploring - this skill handles discovery internally. Also covers nx-import (merge repos) and nx-plugins (list/add) in sections below.
---

# Nx Generate

Скаффолд через Nx-генераторы. Портирован из `.agents/skills/nx-generate`
(+ `nx-import`, `nx-plugins` разделами ниже) в portable `.opencode` pack.

## Key Principles

1. **Всегда `--no-interactive`** — иначе hung на промпте.
2. **Читай исходники генератора** — схемы недостаточно.
3. **Совпадай с паттернами репо** — изучи соседние артефакты до генерации.
4. **Верифицируй** реальным раннером (lint/test/build/typecheck по воркспейсу).

## Steps

### 1. Discover Available Generators

```bash
npx nx list
npx nx list @nx/react
```

Список включает plugin-генераторы (`@nx/react:library`) и локальные workspace-генераторы.

### 2. Match Generator to User Request

Определи тип артефакта + фреймворк + имя генератора из слов пользователя.
**Приоритет: локальный `tools/generators/` всегда выше внешнего plugin-генератора**
(локальные заточены под паттерны репо). Нет подходящего — стоп, честно скажи
(бремя доказательства высокое — проверь все прежде чем сдаться).

Библиотеки по умолчанию — **non-buildable** (без `--bundler`, source потребляется
напрямую). Buildable (`--bundler=vite|swc`) — только для публикации в npm /
кросс-репо / стабильных кэш-хитов. Неясно — спроси пользователя.

### 3. Get Generator Options

```bash
npx nx g @nx/react:library --help
```

Смотри required/defaults/релевантные запросу опции.

### 4. Read Generator Source Code (критично)

Схема не показывает сайд-эффекты. Найди исходники:

```bash
node -e "console.log(require.resolve('@nx/<plugin>/generators.json'));"
```

либо читай `node_modules/<plugin>/generators.json`; локальные — ищи по имени
в `tools/generators/` (или локальной plugin-директории). Пойми: какие файлы
создаст/изменит, что обновит в конфигах, ставит ли deps, как опции взаимодействуют.
После чтения пересмотри выбор генератора (шаг 2).

> `--directory` — это ПОЛНЫЙ путь артефакта, не родитель:
> `nx g @nx/react:library --directory=libs/my-lib` ✅,
> `--name=my-lib --directory=libs` ❌ (рассыпет файлы по `libs/`).

### 5. Examine Existing Patterns

До генерации изучи target-область: соседние либы/приложения, naming, структуру,
test-runner/build/linter. Настрой генератор под них.

### 6. Dry-Run First (обязательно)

```bash
npx nx g @nx/react:library --name=my-lib --dry-run --no-interactive
```

Внимательно проверь размещение файлов. Не туда — корректируй опции по исходникам
(шаг 4). Если dry-run не поддерживается (генератор ставит npm-пакеты) — иди в run.

### 7. Run the Generator

```bash
npx nx generate <generator-name> <options> --no-interactive
```

Новые пакеты часто надо долинковать: см. скилл `link-workspace-packages`
(`pnpm add --filter <consumer> --workspace`).

### 8. Modify Generated Code (If Needed)

Генератор — стартовая точка. Допили импорты/экспорты/конфиги под запрос.
Заменил/удалил сгенерированные `*.spec.ts` — либо напиши осмысленные тесты,
либо убери `test` target из конфига (пустой suite роняет `nx test`).

### 9. Format and Verify

```bash
npx nx format --fix
npx nx run-many -t build,lint,test,typecheck
```

Targets примерные — сверься с CI воркспейса что критично. Изменения могут
задевать соседние проекты — проверяй шире чем один артефакт. Мелкие lint/type
чини сам; обширные поломки — чини очевидное, дальше эскалируй пользователю
(что сгенерировано, что падает, что пробовал).

---

## nx-import (внутри этого файла)

Импорт репозиториев в Nx-воркспейс (`nx import`, сохраняет историю).
Полный исходник: `.agents/skills/nx-import` (здесь — сжатый рецепт).

```bash
npx nx import --help
```

- **Subdirectory-at-a-time (рекомендуется для монорепо-источников):**
  `nx import <source> apps --source=apps` — файлы ложатся наверх без лишнего конфига.
  Caveats: несколько import-команд = несколько merge-коммитов; dest-каталог обязан
  быть пуст (`libs/utils+models` vs `libs/ui+data-access` — импортируй по одной либе);
  root-конфиги НЕ переносятся. Конфликт директорий — импортируй в `imported-apps/` и переименуй.
- **Whole repo (только non-monorepo источники):** `nx import <source> imported --source=.`
  Для монорепо даст мусор (`imported/nx.json`, `imported/tsconfig.base.json`).
- **Конвенции dest важнее source:** source `libs/` → dest `packages/`?
  Импортируй в `packages/` (`nx import <source> packages/foo --source=libs/foo`).
  Applications → `apps/<name>` (проверь `pnpm-workspace.yaml` glob `apps/*`, добавь до импорта).
  Libraries → существующая конвенция dest (`packages/`/`libs/`).
- **Критично после импорта:**
  - pnpm globs: `nx import` пишет сам каталог (`apps`), а не glob (`apps/*`) — замени на globs источника + `pnpm install`.
  - Root-зависимости/конфиг НЕ переносятся: `dependencies/devDependencies` из `package.json`,
    `targetDefaults`/`namedInputs`/plugins из `nx.json` — сдиффай и домержи руками.
  - `nx sync --yes` (тихо + typecheck падает → `nx reset`, затем снова `sync --yes`).
  - ESLint: subdirectory-импорт не несёт root `eslint.config.mjs` — сначала
    `pnpm add -wD eslint@^9 @nx/eslint-plugin typescript-eslint`, затем конфиг, затем `npx nx add @nx/eslint`.
    **ESLint pin v9** (`eslint@^9.0.0`): v10 ломает `@nx/eslint`; при `allow`-ошибках добавь `pnpm.overrides: {eslint: ^9.0.0}`.
  - `noEmit:true` → `composite:true + emitDeclarationOnly + declarationMap + outDir:dist + tsBuildInfoFile` (иначе TS6310/typecheck disabled).
  - Удали stale `node_modules/pnpm-lock.yaml/pnpm-workspace.yaml/.gitignore/nx.json` whole-repo импорта (но `tsconfig.base.json` не сноси вслепую — проекты могут его extends).
  - Frontend tsconfig: root обязан `module:esnext + moduleResolution:bundler + lib:[...dom, dom.iterable] + jsx:react-jsx` (пресет `nodenext/es2022` ломает фронт).
  - Дубли имён проектов (`MultipleProjectsWithSameNameError`) — переименуй (`@org/api` → `@org/teama-api`) + обнови ссылки + `pnpm install`.
  - `workspace:*` порядок: сначала импортируй все проекты, затем `pnpm install --no-frozen-lockfile`.

## nx-plugins (внутри этого файла)

Поиск и установка Nx-плагинов. Полный исходник: `.agents/skills/nx-plugins`.

```bash
pnpm nx list
pnpm nx add @nx/react
```

- Subdirectory-импорт плагины НЕ детектит — добавляй руками (`npx nx add @nx/PLUGIN`), проверь `include/exclude` под альтернативные директории, затем `npx nx reset`.
- Jest: `npx nx add @nx/jest` + создай root `jest.preset.js` + `pnpm add -wD jest jest-environment-jsdom ts-jest @types/jest`.
- React lib typings (`@nx/react/typings/*.d.ts`) требуют `pnpm add -wD @nx/react`.

---

## Exclusion-нота: `monitor-ci` НЕ внедряется

Скилл `.agents/skills/monitor-ci` (Nx Cloud CI мониторинг) **намеренно исключён**
из portable pack: в данном воркспейсе нет Nx Cloud (`nxCloudId` отсутствует в `nx.json`),
мониторить нечего. При появлении Nx Cloud — портировать отдельным решением.
Проверка: `monitor-ci` обязан отсутствовать в `.opencode/skills/`, `.opencode/agent/`,
`opencode.json` (см. верификацию ниже).
