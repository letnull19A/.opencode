---
name: task-manager
description: Manage Trello cards with a project tag via .opencode/scripts/task-manager/*. Use when any agent needs to file a task, move a card, resolve board/list names, or audit board status without guessing. Never writes code; code is handled by build/refactor agents via separate commands.
---

Ты умеешь качественно работать с Trello через скрипты пака, а не через
прямые вызовы API. Все команды — из корня проекта. Если в сессии доступен
агент `@task-manager` — предпочтителен он (у него зажаты права); этот скилл —
для остальных случаев и для проверки чужой работы.

## Предпосылки

- Ключи только из окружения: `TRELLO_API_KEY` + `TRELLO_TOKEN`
  (https://trello.com/app-key). Нет ключей — дальше не идёшь, показываешь
  подсказку и останавливаешься. Ключи не просишь в чат, в файлы не пишешь.
- Тег проекта живёт в `.trello-project` (env: `NAME=owner/repo`, опционально
  `BOARD=`/`LIST=`). Нет файла или пустой NAME — сначала `init.sh`.

## Рецепты (порядок важен)

1. Тег проекта (идемпотентно, повтор безопасен):
   `bash .opencode/scripts/task-manager/init.sh`
   Повтор без `--force` просто покажет файл. Другой тег:
   `init.sh --name <tag> --force`. Нет git remote — скрипт скажет спросить
   тег у пользователя явно; так и делаешь, не выдумываешь.
2. Разведка (только чтение, подтверждения не надо):
   `bash .opencode/scripts/task-manager/boards.sh` — точные имена досок;
   `bash .opencode/scripts/task-manager/lists.sh --board "<name>"` — листы.
3. Проверка дублей — перед созданием, обязательно:
   `bash .opencode/scripts/task-manager/find_duplicates.sh --title "<t>" [--desc "<d>"] --board "<b>" --json`
   Stdout — JSON `{count, duplicates:[{name, shortUrl, similarity, reason}]}`. Если `count>0` и `similarity≥0.65` — семантический дубль: **не создаёшь новую карточку**, а выносишь ссылку на существующую (`shortUrl`) в описание/комментарий новой задачи или говоришь пользователю: «похоже на [дубль](url) — сделать ссылку?». Порог `--threshold 0.5` для проверки, `--threshold 0.65` для автоблока. Для аудита всех дублей: `find_duplicates.sh --all --board "<b>" --json` (пары с `similarity`).
4. Создание — сразу, без черновика и «да» (просьба уже приказ), но строго по формату (неполную не создаёшь — уточняешь) **и только если дублей нет**:
   - Заголовок: императив, что + где, до ~80 символов, без точки; один результат.
   - Описание по шаблону: `## Контекст` / `## Что сделать` (нумерованные шаги) /
     `## Критерии приёмки` (`- [ ] ...`) / `## Связи` (`Blocked by: <url>` + при дубле `Related: <shortUrl>`, если есть).
   `bash .opencode/scripts/task-manager/create.sh --title "<t>" --board "<b>" --list "<l>" [--desc "<d>"]`
   Флаги `--board/--list` опускай, только если они уже в дефолтах
   `.trello-project`. Запомнить выбор: добавь `--save-defaults`.
   В ответ — URL карточки, его и ретранслируешь.
   Спрашиваешь только недостающее (пустой заголовок, неизвестные доска/лист).
5. Перемещение — тоже сразу, без «да» и без `--dry-run`:
   `bash .opencode/scripts/task-manager/move.sh (--id <id> | --url <url> | --card "<имя>") --list "<цель>" [--to-board "<b>"] [--pos top|bottom|N]`
   `--dry-run` — только по просьбе «покажи план».
   `--card` без `--from-board` ищет по всем открытым доскам; при дублях
   скрипт перечислит id — уточни через `--id`/`--url`, не гадай.
   «Уже в этом листе» — успех, дублей не делаешь.
6. Подзадачи = пункты чек-листа (шаги одного результата в одном листе):
   `bash .opencode/scripts/task-manager/checklist.sh --url <url> --create "Подзадачи" --items "шаг 1;шаг 2"`
   Добавить: `--add-item "<текст>"`; отметить: `--complete "<пункт>"` / `--uncomplete`;
   прочитать: `--show` (JSON). Карточка — через `--id | --url | --card`, чек-лист —
   через `--list` (точное имя; при единственном можно опустить).
   Независимые куски ценности — отдельные карточки по формату п.4, связанные
   через `## Связи` / `Blocked by`, а не чек-лист.
7. Зависимости — строка `Blocked by: <url>` в секции `## Связи` описания
   (нативного графа в Trello нет; `audit.sh` парсит её в `blocked_by`).
   Пишешь только указанную пользователем зависимость, URL — только точный.
   Заблокированную задачу выполняешь как обычно, но помечаешь в отчёте.
8. Аудит (только чтение, AI-first JSON для `@task-manager`):
   `bash .opencode/scripts/task-manager/audit.sh --board "<name>" [--tag "<t>" | --all]`
   Stdout — только JSON по `schema/audit.schema.json` (`totals/lists/overdue/blocked`).
   Прямо из чата не зовёшь — это делает сабагент `task-audit` по оркестрации `@task-manager`.

## Правила качества

- Точные имена: доски, листы, карточки — только из вывода скриптов или
  из слов пользователя. Почти-совпадение — не совпадение: показываешь
  список из ошибки скрипта и спрашиваешь.
- Дубли: перед каждым `create` — `find_duplicates.sh --title "<t>" --board "<b>" --json`, при `count>0` и `similarity≥0.60` не создаёшь дубль, а показываешь `duplicates[0].shortUrl` и предлагаешь `Related: <url>` в `## Связи` или ссылку в описании. Для аудита всех дублей — `find_duplicates.sh --all --board "<b>"`.
- Код — не зона task-manager: этот скилл только для Trello. Просьба «сделай фичу X / почини Y» — создай карточку `Добавить X` / `Починить Y` в Trello, не вызывай `build`/`refactor`/`unit-test` и не пиши код. Код — у `@build`/`@refactor` по отдельной команде.
- Trello REST касается только `scripts/task-manager/*`. Никакого ручного
  curl к `api.trello.com`, никаких id из головы, никаких «одноразовых»
  python-сниппетов вместо скриптов.
- Мутации (`create`, `move`) — выполняешь сразу по просьбе пользователя,
  по одной за раз, без «да». Вопросы — только про недостающие данные.
  Чтение (`boards`, `lists`, `audit`, `init`, `move --dry-run`) —
  свободно, пачками при независимых вызовах.
- Ошибка скрипта — не повод импровизировать: вставляешь вывод как есть,
  следуешь его подсказке (обычно там уже список доступных имён).
- `.trello-project` без секретов — напоминаешь, что его можно коммитить;
  сами ключи в репозиторий не попадают никогда.

## Типичные связки

```bash
# Новая задача с нуля (первый раз в проекте):
bash .opencode/scripts/task-manager/init.sh
bash .opencode/scripts/task-manager/boards.sh
bash .opencode/scripts/task-manager/lists.sh --board "My board"
# → проверка дублей → сразу выполняешь (без черновика и «да») →
bash .opencode/scripts/task-manager/find_duplicates.sh --title "Fix login" --board "My board" --json
bash .opencode/scripts/task-manager/create.sh --title "Fix login" --board "My board" --list "To Do" --save-defaults

# Следующие задачи (дефолты уже запомнены):
bash .opencode/scripts/task-manager/find_duplicates.sh --title "Next fix" --json
bash .opencode/scripts/task-manager/create.sh --title "Next fix"

# Сдвиг задачи по канбану (сразу, без --dry-run и «да»):
bash .opencode/scripts/task-manager/move.sh --card "Fix login" --list "Doing"

# Подзадачи чек-листом + отметка выполнения:
bash .opencode/scripts/task-manager/checklist.sh --card "Fix login" --create "Подзадачи" --items "Повторить баг;Починить;Покрыть тестом"
bash .opencode/scripts/task-manager/checklist.sh --card "Fix login" --complete "Повторить баг"

# Аудит доски (читает task-audit по оркестрации @task-manager, stdout — JSON):
bash .opencode/scripts/task-manager/audit.sh --board "My board"
```
