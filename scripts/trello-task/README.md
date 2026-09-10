# trello-task — задачи в Trello с тегом проекта

Пайплайн как у issue-writer: **думает только агент** (`@trello-task`),
всё детерминированное — в коде. Агент сам Trello API не касается
(никакого curl вручную) — он гоняет скрипты и ретранслирует вывод.

```
[/new-task "текст"] → @trello-task (subagent)
  1. init.sh            → .trello-project (NAME=owner/repo из git remote)
  2. boards.sh/lists.sh → точные имена доски/листа (агент не выдумывает)
  3. черновик → явное «да» пользователя
  4. create.sh          → карточка с меткой NAME → URL
[@trello-task "перемести X в Done"] → move.sh → карточка в целевом листе
```

## Файлы

- `.opencode/agent/trello-task.md` — агент (`mode: all`: и primary через
  Tab, и subagent через `@` / `/new-task`). Права зажаты: `edit: deny`,
  bash только на `scripts/trello-task/*`, вопросы разрешены.
- `.opencode/commands/new-task.md` — команда `/new-task`, делегирует
  агенту trello-task (выполняется как subagent, контекст не засоряет).
- `.opencode/scripts/trello-task/_common.sh` — общий код (не запускать):
  ключи только из env, curl-обёртки, резолв доски/листа по точным именам,
  создание метки проекта. Требует `curl`, `python3` (stdlib).
- `.opencode/scripts/trello-task/init.sh` — тег проекта → `.trello-project`
  (env-формат, без секретов, можно коммитить). По умолчанию
  `owner/repo` из git remote нижним регистром; `--name` перекрывает;
  без remote просит спросить тег у пользователя явно.
- `.opencode/scripts/trello-task/boards.sh` — мои открытые доски (id + имя).
- `.opencode/scripts/trello-task/lists.sh --board "<name>"` — листы доски.
- `.opencode/scripts/trello-task/create.sh` — карточка с меткой NAME.
  `--board/--list` можно опустить, если BOARD/LIST уже в `.trello-project`;
  `--save-defaults` их туда записывает.
- `.opencode/scripts/trello-task/move.sh` — перемещение карточки в другой
  лист (той же или другой доски): `--id | --url | --card` (+ `--from-board`
  для сужения поиска по имени) → `--list` (+ `--to-board`, по умолчанию
  текущая доска) → PUT `idList`+`pos`. `--dry-run` показывает план без PUT.

## Поведение

- Создание карточки — только после черновика + явного «да» (как `create`
  в issue-writer). `boards.sh`/`lists.sh`/`init.sh` — чтение или локальный
  файл, подтверждения не требуют.
- Несовпадение имён (нет доски/листа, дубли) — ненулевой exit со списком
  доступных; агент показывает список и спрашивает, а не гадает.
- Нет `TRELLO_API_KEY`/`TRELLO_TOKEN` — понятная ошибка с подсказкой
  (ключи: `https://trello.com/app-key`). Секреты только в env/`.env`,
  в репозиторий не коммитить.
- Скрипты намеренно НЕ в allowlist `opencode.json`: создание внешних
  карточек — side effect, первый запуск спросит подтверждение сам opencode.
- `.trello-project` живёт в корне consumer-репозитория (CWD), формат:
  `NAME=owner/repo`, опционально `BOARD=<точное имя>`, `LIST=<точное имя>`.

## Быстрый прогон вручную (без opencode)

```bash
bash .opencode/scripts/trello-task/init.sh            # тег из git remote → .trello-project
bash .opencode/scripts/trello-task/init.sh --name myproj --force
export TRELLO_API_KEY=... TRELLO_TOKEN=...
bash .opencode/scripts/trello-task/boards.sh
bash .opencode/scripts/trello-task/lists.sh --board "My board"
bash .opencode/scripts/trello-task/create.sh --title "Test" --board "My board" --list "To Do" --save-defaults
bash .opencode/scripts/trello-task/create.sh --title "Next"   # доска/лист уже из дефолтов
bash .opencode/scripts/trello-task/move.sh --card "Next" --list "Doing" --dry-run
bash .opencode/scripts/trello-task/move.sh --card "Next" --list "Doing"   # только после «да» пользователя
```
