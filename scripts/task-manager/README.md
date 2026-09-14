# task-manager — задачи в Trello с тегом проекта + аудит

Пайплайн как у issue-writer: **думает агент-оркестратор** (`@task-manager`),
всё детерминированное — в коде. Агент сам Trello API не касается
(никакого curl вручную) — он гоняет скрипты и ретранслирует вывод.
Аудит выполняет сабагент `task-audit` (только чтение, возврат строго JSON).

```
[/new-task "текст"] → @task-manager (subagent)
  1. init.sh            → .trello-project (NAME=owner/repo из git remote)
  2. boards.sh/lists.sh → точные имена доски/листа (агент не выдумывает)
  3. create.sh          → карточка по строгому формату → URL (сразу, без «да»)
  4. checklist.sh       → подзадачи чек-листом (если 2+ шагов одного результата)
[@task-manager "перемести X в Done"] → move.sh → карточка в целевом листе (сразу, без «да»)
[@task-manager "аудит/статус"] → task-audit → audit.sh → JSON → рендер человеку
```

## Формат задачи (строгий)

Неполную задачу агент НЕ создаёт — уточняет вопросом. Заголовок: императив,
что + где, до ~80 символов, без точки, один проверяемый результат. Описание
строго по шаблону: `## Контекст` / `## Что сделать` (шаги) /
`## Критерии приёмки` (`- [ ]`) / `## Связи` (`Blocked by: <url>`, если есть).

## Файлы

- `.opencode/agent/task-manager.md` — оркестратор (`mode: all`: и primary через
  Tab, и subagent через `@` / `/new-task`). Права зажаты: `edit: deny`,
  bash только на `scripts/task-manager/*`, разрешены вопросы и делегирование (task).
- `.opencode/agent/task-audit.md` — сабагент аудита (`mode: subagent`, только
  оркестрация через `@task-manager`). Возвращает ТОЛЬКО JSON по
  `schema/audit.schema.json`, вопросов пользователю не задаёт.
- `.opencode/commands/new-task.md` — команда `/new-task`, делегирует
  агенту task-manager (выполняется как subagent, контекст не засоряет).
- `.opencode/scripts/task-manager/_common.sh` — общий код (не запускать):
  ключи только из env, curl-обёртки, резолв доски/листа по точным именам,
  создание метки проекта. Требует `curl`, `python3` (stdlib).
- `.opencode/scripts/task-manager/init.sh` — тег проекта → `.trello-project`
  (env-формат, без секретов, можно коммитить). По умолчанию
  `owner/repo` из git remote нижним регистром; `--name` перекрывает;
  без remote просит спросить тег у пользователя явно.
- `.opencode/scripts/task-manager/boards.sh` — мои открытые доски (id + имя).
- `.opencode/scripts/task-manager/lists.sh --board "<name>"` — листы доски.
- `.opencode/scripts/task-manager/create.sh` — карточка с меткой NAME.
  `--board/--list` можно опустить, если BOARD/LIST уже в `.trello-project`;
  `--save-defaults` их туда записывает.
- `.opencode/scripts/task-manager/move.sh` — перемещение карточки в другой
  лист (той же или другой доски): `--id | --url | --card` (+ `--from-board`
  для сужения поиска по имени) → `--list` (+ `--to-board`, по умолчанию
  текущая доска) → PUT `idList`+`pos`. `--dry-run` показывает план без PUT.
- `.opencode/scripts/task-manager/checklist.sh` — подзадачи чек-листом:
  `--create "<чек-лист>" [--items "a;b;c"]`, `--add-item`, `--complete` /
  `--uncomplete`, `--show` (JSON). Карточка — `--id | --url | --card`
  (+ `--from-board`), чек-лист — точным `--list` (при единственном опускается).
- `.opencode/scripts/task-manager/audit.sh` — read-only аудит доски, stdout —
  ТОЛЬКО JSON (AI-first для `task-audit`): `--board "<name>"` (точное имя
  или дефолт BOARD) + фильтр по метке (`NAME` по умолчанию, `--tag` перекрывает,
  `--all` — без фильтра) + `--limit N` (карточек на лист, по умолчанию 50).
  Просрочки (`due < now && !dueComplete`) и зависимости (`Blocked by:` в описании)
  считает скрипт, агент даты не сравнивает и зависимости не выдумывает.
- `.opencode/scripts/task-manager/audit.sh` — read-only аудит доски, stdout —
  ТОЛЬКО JSON (AI-first для `task-audit`): `--board "<name>"` (точное имя
  или дефолт BOARD) + фильтр по метке (`NAME` по умолчанию, `--tag` перекрывает,
  `--all` — без фильтра) + `--limit N` (карточек на лист, по умолчанию 50).
  Просрочки (`due < now && !dueComplete`) считает скрипт, агент даты не сравнивает.
- `.opencode/scripts/task-manager/schema/audit.schema.json` — контракт
  `task-audit → task-manager` (`board/tag/filter/fetched_at/totals/lists/overdue/blocked`).
- Зависимости — соглашение пайплайна (нативного графа в Trello нет): строка
  `Blocked by: <url>` в описании карточки; `audit.sh` парсит её в `blocked_by`.

## Поведение

- Создание/перемещение карточки — сразу по просьбе пользователя, без
  черновика и «да» (просьба уже приказ). Вопросы — только про недостающие
  данные (пустой заголовок, неизвестные доска/лист). `--dry-run` у `move.sh` —
  только по просьбе «покажи план».
- Аудит — только через оркестрацию: пользователь просит `@task-manager`,
  тот делегирует `task-audit`, тот гоняет `audit.sh` и возвращает JSON.
  Прямой вызов `@task-audit` запрещён.
- Несовпадение имён (нет доски/листа, дубли) — ненулевой exit со списком
  доступных; агент показывает список и спрашивает, а не гадает.
  `audit.sh` в этом случае печатает `{"error": ...}` JSON.
- Нет `TRELLO_API_KEY`/`TRELLO_TOKEN` — понятная ошибка с подсказкой
  (ключи: `https://trello.com/app-key`). Секреты только в env/`.env`,
  в репозиторий не коммитить.
- Скрипты намеренно НЕ в allowlist `opencode.json`: создание внешних
  карточек — side effect, первый запуск спросит подтверждение сам opencode.
- `.trello-project` живёт в корне consumer-репозитория (CWD), формат:
  `NAME=owner/repo`, опционально `BOARD=<точное имя>`, `LIST=<точное имя>`.

## Быстрый прогон вручную (без opencode)

```bash
bash .opencode/scripts/task-manager/init.sh            # тег из git remote → .trello-project
bash .opencode/scripts/task-manager/init.sh --name myproj --force
export TRELLO_API_KEY=... TRELLO_TOKEN=...
bash .opencode/scripts/task-manager/boards.sh
bash .opencode/scripts/task-manager/lists.sh --board "My board"
bash .opencode/scripts/task-manager/create.sh --title "Test" --board "My board" --list "To Do" --save-defaults
bash .opencode/scripts/task-manager/create.sh --title "Next"   # доска/лист уже из дефолтов
bash .opencode/scripts/task-manager/move.sh --card "Next" --list "Doing"   # сразу, без «да» (--dry-run только по просьбе «покажи план»)
bash .opencode/scripts/task-manager/checklist.sh --card "Next" --create "Подзадачи" --items "Шаг 1;Шаг 2"
bash .opencode/scripts/task-manager/audit.sh --board "My board" | python3 -m json.tool  # JSON для task-audit
```
