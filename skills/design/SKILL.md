---
name: design
description: Enforce DESIGN.md style-guide via .opencode/scripts/design/* (context injection, pre-commit guard). Use when any agent touches UI files — read the rules programmatically, never from memory, and gate the commit.
---

`DESIGN.md` в корне consumer-проекта — style-guide (токены, `box-shadow`, тёмная тема, a11y), владелец — человек. Ты его только читаешь (UI-ядро — строгий read-only) и исполняешь скрипты. Все команды — из корня consumer-репо.

## Когда вызывать

- Начало UI-задачи: инжект контекста → работа строго по нему.
- Перед `git add`/`/commit` каждой группы с UI-файлами: guard → error = стоп + явный approve человека.

## Рецепты (порядок важен)

```bash
bash .opencode/scripts/design/init.sh --check
```

```bash
bash .opencode/scripts/design/context.sh
```

```bash
bash .opencode/scripts/design/context.sh --json
```

```bash
bash .opencode/scripts/design/guard.sh --staged --json
```

- `init.sh --check`: файла нет (exit 1) — `init.sh` (создать из шаблона, есть — no-op) + первичное заполнение разделов по коду/опросу. Без файла дальше не идёшь.
- `context.sh`: компактный блок правил (стек, токены, конвенции, последние 5 решений) — вставляешь в контекст как есть, не пересказываешь.
- `guard.sh [--staged] [--json]`: сверяет НЕЗАКОММИЧЕННЫЕ UI-изменения с токенами. `error` (`magic-color`, `box-shadow`, `design-not-updated`) блокирует коммит; `warn` (`magic-px`) — нет.

## Таблица замен (нарушение → делай так)

- `magic-color` (hex/rgba-литерал вне токенов) → замени на токен `DESIGN.md`; токена нет — предложи человеку точный патч (секция → строки), правит он.
- `box-shadow` в коде → только `border`/`outline` (§2/§5).
- `design-not-updated` → нарушения есть, а `DESIGN.md` не тронут: отдаёшь точные предлагаемые правки токенов человеку, вносит он, затем approve → коммит.
- Файла `DESIGN.md` для пути нет → файл помечается `files_without_design`, по дизайну не проверяется (не ошибка).

## Правила

- Конвенции проекта важнее best practices; противоречие — вопрос человеку, не тихий отход.
- Guard флагами не отключаешь, `design:ignore` — только с доказанной причиной.
- Скилл прав не даёт: нет `scripts/design/*` в allowlist — просишь родителя/человека.
