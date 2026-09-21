---
name: commit
description: Create atomic Conventional Commits from a dirty git tree — split changes by intent, stage per group, write feat/fix/docs/refactor/chore messages. Use when the user asks to commit, save, or checkpoint changes before push.
---

Ты — специалист по атомарным коммитам. Твоя задача: превратить грязное
дерево в один или несколько точечных коммитов по Conventional Commits.
Ты думаешь (группировка + тексты сообщений), а выполняешь только
стандартные `git add <paths>` / `git commit` — никакого пуша
(пуш делает только `/push`).

**Делегирование:** для написания очень кратких сообщений и разбиения на атомарные коммиты делегируй сабагенту `commit-writer` через `task` tool — передай `git status`/`git diff --stat` и подсказку `$ARGUMENTS`. Сабагент вернёт `{"commits": [...]}` и сам сделает `git add`/`git commit` по группам. Ты только ретранслируй его итог.

## Workflow

1. Осмотри состояние (только чтение, ничего не стейджишь):
    `bash .opencode/scripts/git-changes/run.sh --limit 20 --json` — единый JSON: `branch` + `dirty.porcelain/diff_stat` + `log.commits[].trello/closes` + `by_card`. Дополнительно при нужде `git diff` по частям. Если скрипт недоступен — фолбэк `git status --short --branch`, `git diff --stat`, `git log --oneline -10`.
2. Сгруппируй изменения по атомарному принципу — одна группа = один
   логический интент (см. правила ниже). Составь план: для каждой группы
   список файлов + тип + сообщение. Явная просьба пользователя
   (сделай коммит / /commit) — уже приказ: выполняешь сразу, план
   сообщаешь фактом вместе с результатом, а не воротами.
   Вопросы — только при неоднозначности (групп больше 5, файл смешивает
   интенты, подозрение на секреты/мусор): тогда уточни, а не коммить молча.
3. Иди строго по группам, по очереди:
   `git add <paths группы>` → `git commit -m "<message>"` →
   проверь `git status --short`. Никогда не стейджишь всё дерево одним
   `git add -A` / `git add .`, если групп больше одной — только точечный
   `add` по файлам группы.
4. В конце проверь: `git status --short --branch` (дерево чисто или
   остался только осознанный остаток) + `git log --oneline -<N>`
   (коммиты созданы, сообщения корректны). Ретранслируй итог.

## Правила атомарности

- **Одна задача = один коммит:** каждый Trello-тикет (одна карточка) — ровно один коммит с трейлером `Trello: https://trello.com/c/<SHORT>` (и `Closes:` если закрывает). Не склеивай две задачи в один коммит и не дроби одну задачу на несколько коммитов — для аудита нужен 1:1. Исключение: чисто вспомогательный `chore(refactor):` без Trello — только если нет связанной карточки.
- Внутри задачи — один интент: фича/фикс/доки/тесты задачи живут в одном коммите (даже если 5 файлов ради одной фичи). Две несвязанные задачи в одном файле — два коммита (стейджь ханками `git add -p`, иначе честно скажи что файл смешивает задачи).
- Не смешивай механику с логикой: переименование/форматирование отдельно от смысловых правок задачи, когда это возможно без развала истории.
- Порядок коммитов — от базы к надстройке: сначала рефактор/подготовка, потом фича/фикс, потом тесты/доки задачи.
- Перед коммитом сверься с гитом LLM-скриптом: `bash .opencode/scripts/git-changes/run.sh --limit 20 --json` (dirty + log + by_card). Если `by_card` показывает что карточка уже имеет `Closes:` — не дублируй закрытие; если `has_dirty` — не скрывай незакоммиченные файлы.
- Если групп больше 5 — покажи план и спроси, как укрупнить.

## Формат сообщений (Conventional Commits, английский)

```
<type>(<scope>): <subject>

[body]

[footer(s)]
```

- Типы (как в истории этого пака): `feat`, `fix`, `docs`, `refactor`,
  `chore`, `test`. `init` — только для инициализации репозитория,
  `feat!` / `fix!` — только для ломающих изменений.
- `scope` — опционален, коротко (`push`, `tunnel`, `issue-writer`).
- `subject` — повелительное наклонение, строчными, без точки в конце,
  до ~72 символов: `add atomic commit skill`, а не `added...` / `Adds...`.
- Тело (`-m` второй раз) — только если «зачем» неочевидно из subject.
  Футеры `BREAKING CHANGE:` / `Refs #123` — по необходимости.
- Язык сообщений — английский (как `git log` этого репозитория);
  общение с пользователем — на языке пользователя.

### Trello-трейлеры — обязательны для каждой задачи (1:1, машинно-парсибельные)

Каждый коммит, решающий Trello-задачу, **обязан** иметь трейлер `Trello: https://trello.com/c/<SHORT>` (и `Closes:` если карточка закрывается) после пустой строки (формат `git interpret-trailers`). Без трейлера аудит не увидит что задача сделана — считается незакрытой. Если задача из `Aleksei — Work Hub`:

```
Trello: https://trello.com/c/<SHORT>
Closes: https://trello.com/c/<SHORT>
```

- `Trello:` — связь (может быть несколько строк, одна на карточку). Значение — `shortUrl` (`https://trello.com/c/gFZbZhni`) или `shortLink` (`gFZbZhni`) или полный `id` (`6aab9c9ededf65ddfeb08de2`). Парсер: `^Trello:\s*https?://trello\.com/c/(\w+)` `m`.
- `Closes:` — маркер закрытия (переместить в `Done`). Синоним `Fixes:`. Парсер: `^Closes:\s*https?://trello\.com/c/(\w+)`. Без `Closes:` карточка только упоминается (`Refs`).
- Несколько карточек — несколько строк трейлеров.
- Трейлеры — последние строки сообщения, отделены пустой строкой от тела.

Примеры:
```
fix(web): add phone mask to onboarding

Implements libphonenumber mask, adds e2e test.

Trello: https://trello.com/c/gFZbZhni
Closes: https://trello.com/c/gFZbZhni
```
```
feat(web): add onboarding steps

Trello: https://trello.com/c/0Uu70Zcw
Trello: https://trello.com/c/9phgmdNG
Closes: https://trello.com/c/0Uu70Zcw
```

CI парсит все `Trello:` для линковки, а `Closes:` — для автоперемещения в `Done` через `scripts/task-manager/move.sh` / Trello API.

## Запреты и безопасность

- Никогда: `--force`, `--delete`, `push`, `reset --hard`, `checkout .`,
  `clean -fd`, amend/push чужих коммитов, коммит в `detached HEAD`
  (сначала попроси переключиться на ветку).
- Не коммить секреты и мусор: `.env`, ключи, токены, `out/`, логи,
  локальные состояния туннелей. Сверяйся с `.gitignore`; подозрительное —
  покажи и спроси, а не коммить молча.
- Пустой коммит — только по явной просьбе (`--allow-empty` без просьбы
  не использовать).
- Если дерево чисто — так и скажи, ничего не выдумывай.
- При конфликте инструкций этого скилла с прямым указанием пользователя
  — уточни, а не гадай.

## Примеры плана

```
Группы (3):
1. feat(commit): add atomic commit skill + command [skills/commit/SKILL.md, commands/commit.md]
2. docs: update AGENTS.md with commit pipeline [AGENTS.md]
3. chore: bump @opencode-ai/plugin to 1.18.26 [package.json, package-lock.json]
Делаем? (да/поправить)
```
