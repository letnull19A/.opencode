---
name: check
description: Verify only uncommitted changes via .opencode/scripts/check/run.sh (typecheck/lint/format + env/yaml/compose gates). Use when any agent must validate its diff before done/commit/review — never hand-rolled tsc/eslint invocations.
---

Ты проверяешь НЕЗАКОММИЧЕННЫЕ файлы программным гейтом, а не ручными командами. Все вызовы — из корня consumer-репо, по одному за раз.

## Когда вызывать

- После каждого шага правок (`edit`) и обязательно перед `done`/`/commit`/`@review`.
- Упал `typecheck/lint` в чужом файле — не чинишь, показываешь вывод и останавливаешься.

## Рецепты

```bash
bash .opencode/scripts/check/run.sh --json
```

```bash
bash .opencode/scripts/check/run.sh --staged --json
```

```bash
bash .opencode/scripts/check/run.sh --typecheck --json
```

```bash
bash .opencode/scripts/check/run.sh --lint --json
```

```bash
bash .opencode/scripts/check/run.sh --format --json
```

- Без флагов — всё сразу (только по изменённым файлам, не по всему репо).
- `--staged` — только staged (перед коммитом); по умолчанию staged+unstaged+untracked.
- `env`/`yaml`/`compose` проверяются всегда, флагами не отключаются.
- Выход: stdout — только JSON, stderr — human summary. Exit `0` чисто, `1` есть ошибки, `2` нет файлов.

## Таблица гейтов (что чинить)

- `env` — запрет `#`-комментариев в `.env*`, синтаксис `KEY=VALUE`, валидные имена, без дубликатов и вложенных дефолтов (`${A:-${B}}`). Лечится правкой `.env`, пояснения — в `README.md`, не в `.env`.
- `yaml` — парсинг (табы/дубли ключей/кавычки); compose-файл без top-level `services:` — ошибка.
- `compose` — сервис с `build:` без `image:` — ошибка: либо `image: <registry>/<name>:<tag>` (образ публикует CI), либо маркер `# local-build: <причина>` + строка в README.

## Правила

- Провал в твоих файлах — чинишь своё. Провал в чужих — не трогаешь, показываешь вывод.
- Проверку флагами не отключаешь, `sec:ignore`-стиль обходов не выдумываешь.
- Скилл прав не даёт: нет `scripts/check/*` в allowlist — просишь родителя/человека, не обходишь сырыми `tsc`/`eslint`.
