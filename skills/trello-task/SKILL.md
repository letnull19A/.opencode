---
name: trello-task
description: Create and move Trello cards with a project tag via .opencode/scripts/trello-task/*. Use when any agent needs to file a task, move a card, or resolve Trello board/list names without guessing.
---

Ты умеешь качественно работать с Trello через скрипты пака, а не через
прямые вызовы API. Все команды — из корня проекта. Если в сессии доступен
агент `@trello-task` — предпочтителен он (у него зажаты права); этот скилл —
для остальных случаев и для проверки чужой работы.

## Предпосылки

- Ключи только из окружения: `TRELLO_API_KEY` + `TRELLO_TOKEN`
  (https://trello.com/app-key). Нет ключей — дальше не идёшь, показываешь
  подсказку и останавливаешься. Ключи не просишь в чат, в файлы не пишешь.
- Тег проекта живёт в `.trello-project` (env: `NAME=owner/repo`, опционально
  `BOARD=`/`LIST=`). Нет файла или пустой NAME — сначала `init.sh`.

## Рецепты (порядок важен)

1. Тег проекта (идемпотентно, повтор безопасен):
   `bash .opencode/scripts/trello-task/init.sh`
   Повтор без `--force` просто покажет файл. Другой тег:
   `init.sh --name <tag> --force`. Нет git remote — скрипт скажет спросить
   тег у пользователя явно; так и делаешь, не выдумываешь.
2. Разведка (только чтение, подтверждения не надо):
   `bash .opencode/scripts/trello-task/boards.sh` — точные имена досок;
   `bash .opencode/scripts/trello-task/lists.sh --board "<name>"` — листы.
3. Создание (мутация — только после черновика + явного «да»):
   `bash .opencode/scripts/trello-task/create.sh --title "<t>" --board "<b>" --list "<l>" [--desc "<d>"]`
   Флаги `--board/--list` опускай, только если они уже в дефолтах
   `.trello-project`. Запомнить выбор: добавь `--save-defaults`.
   В ответ — URL карточки, его и ретранслируешь.
4. Перемещение (мутация — тоже только после «да», сначала покажи from → to):
   `bash .opencode/scripts/trello-task/move.sh (--id <id> | --url <url> | --card "<имя>") --list "<цель>" [--to-board "<b>"] [--pos top|bottom|N]`
   Безопасный предпросмотр: тот же вызов + `--dry-run` (ничего не меняет).
   `--card` без `--from-board` ищет по всем открытым доскам; при дублях
   скрипт перечислит id — уточни через `--id`/`--url`, не гадай.
   «Уже в этом листе» — успех, дублей не делаешь.

## Правила качества

- Точные имена: доски, листы, карточки — только из вывода скриптов или
  из слов пользователя. Почти-совпадение — не совпадение: показываешь
  список из ошибки скрипта и спрашиваешь.
- Trello REST касается только `scripts/trello-task/*`. Никакого ручного
  curl к `api.trello.com`, никаких id из головы, никаких «одноразовых»
  python-сниппетов вместо скриптов.
- Мутации (`create`, `move` без `--dry-run`) — по одной за раз, каждую
  после своего «да». Чтение (`boards`, `lists`, `init`, `move --dry-run`) —
  свободно, пачками при независимых вызовах.
- Ошибка скрипта — не повод импровизировать: вставляешь вывод как есть,
  следуешь его подсказке (обычно там уже список доступных имён).
- `.trello-project` без секретов — напоминаешь, что его можно коммитить;
  сами ключи в репозиторий не попадают никогда.

## Типичные связки

```bash
# Новая задача с нуля (первый раз в проекте):
bash .opencode/scripts/trello-task/init.sh
bash .opencode/scripts/trello-task/boards.sh
bash .opencode/scripts/trello-task/lists.sh --board "My board"
# → черновик пользователю → «да» →
bash .opencode/scripts/trello-task/create.sh --title "Fix login" --board "My board" --list "To Do" --save-defaults

# Следующие задачи (дефолты уже запомнены):
bash .opencode/scripts/trello-task/create.sh --title "Next fix"

# Сдвиг задачи по канбану:
bash .opencode/scripts/trello-task/move.sh --card "Fix login" --list "Doing" --dry-run
# → «да» → тот же вызов без --dry-run
```
