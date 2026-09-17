# react-fix — правки React-компонентов по имени класса

Пайплайн как у issue-writer: **думает только агент** (`@react-fix`),
всё рутинное — в коде. Агент сам классы не ищет (никакого ручного
`grep`/`rg` по классам) — он гоняет скрипт и ретранслирует таблицу,
а решения («что и где править») принимает вместе с человеком.

```
[/fix "блок .journal — нет пунктиров ..."] → @react-fix (subagent)
  1. find-class.sh --class journal → таблица FILE|LINE|KIND|TEXT
  2. понятно что/где править? нет → вопрос пользователю (без edit!)
  3. явное «что менять + где» → точечный edit
  4. проверка командами consumer-проекта (typecheck/lint/test)
```

## Файлы

- `.opencode/agent/react-fix.md` — агент (`mode: all`: и primary через
  Tab, и subagent через `@` / `/fix`). Права широкие (править код надо),
  но дисциплина жёсткая: поиск классов — только скриптом, правки — только
  после выясненного «что менять».
- `.opencode/commands/fix.md` — команда `/fix`, делегирует агенту
  react-fix (выполняется как subagent, контекст не засоряет).
- `.opencode/skills/react-fix/SKILL.md` — то же для остальных агентов
  (рецепты поиска/уточнения/правки, разбор таблицы).
- `.opencode/scripts/react-fix/find-class.sh` — поиск класса:
  точное имя + BEM-дети (`__el`/`--mod`) в разметке (`className`,
  `clsx`/`cn`, `styles.x`) и в стилях (селекторы, псевдоклассы).
  Подстроки отсекаются (`journal` ≠ `journalism`); camelCase-ключи
  модулей (`styles.journalTitle`) — отдельные имена, их искать напрямую.
  Игнорирует `node_modules/dist/build/.git/.next/coverage/out/...`,
  ищет в `tsx/jsx/ts/js/mts/cts/mjs/cjs/css/scss/sass/less`.
  Ищет через `rg` (если есть) или `grep -E`, форматирует через `python3`.
- `.opencode/scripts/react-fix/AGENTS.md.snippet` — что добавить
  в AGENTS.md проекта, чтобы заявки на правки были точными.

## Поведение

- Поиск — чтение, подтверждения не требует, но выполняется ТОЛЬКО
  скриптом. Сырой `grep`/`rg` агенту разрешён для всего остального
  (компоненты, импорты), но не для классов.
- Неясный запрос («это никак в оригинале» без указания элемента) —
  вопрос пользователю, правок нет. Правка без выясненного «что менять» —
  запрещена, даже «очевидная».
- Чеклист из N классов — N отдельных подтверждений, не одно скопом.
- `0 matches` — скрипт печатает подсказку (написание, BEM-суффикс,
  `--root`, генерация кодом); агент идёт по ней и спрашивает, а не гадает.
- Коммитов/пуша в пайплайне нет: изменения — через `/commit`,
  отправка — через `/push`.
- Скрипт read-only (только печатает в stdout) — поэтому он в allowlist
  `opencode.json`, в отличие от мутирующих trello-скриптов.

## Быстрый прогон вручную (без opencode, для проверки скрипта)

```bash
bash .opencode/scripts/react-fix/find-class.sh --class journal
bash .opencode/scripts/react-fix/find-class.sh .journal .header --root src
bash .opencode/scripts/react-fix/find-class.sh --class nosuchclass; echo "exit=$?"
```
