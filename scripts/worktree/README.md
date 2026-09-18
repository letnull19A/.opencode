# worktree — параллельные worktree для opencode

Скрипт оборачивает `git worktree` с обработкой сабмодулей (`.opencode`) и JSON для ИИ. Для параллельной работы агентов — каждый `worktree` — отдельная ветка + отдельная `opencode` сессия.

## Использование (из корня проекта)

```bash
# создать worktree рядом с ROOT (../<repo>-<name>) от base (по умолчанию origin/dev или HEAD)
bash .opencode/scripts/worktree/run.sh create --name <name> [--branch <branch>] [--from <base>] [--json]

# примеры:
bash .opencode/scripts/worktree/run.sh create --name auth --branch feat/auth --from dev
bash .opencode/scripts/worktree/run.sh create --name hotfix --from main --json

# список всех worktrees (JSON для ИИ, таблица для человека)
bash .opencode/scripts/worktree/run.sh list --json
bash .opencode/scripts/worktree/run.sh list

# статус конкретного worktree
bash .opencode/scripts/worktree/run.sh status --name auth --json

# удалить worktree (ветка остаётся, удали вручную если не нужна: git branch -D <branch>)
bash .opencode/scripts/worktree/run.sh remove --name auth
bash .opencode/scripts/worktree/run.sh remove --name auth --force  # с грязными изменениями

# подчистить битые записи
bash .opencode/scripts/worktree/run.sh prune --json
```

## Что делает `create`

1. `git worktree add [-b <branch>] <path> <base>` — создаёт ветку и worktree
2. `git -C <path> submodule update --init --recursive` — если есть `.gitmodules` (подтягивает `.opencode`)
3. Проверяет `.trello-project` (тег проекта наследуется)

Путь по умолчанию: `../<basename>-<name>` рядом с `ROOT` (не внутри `.opencode/.worktrees`, чтобы не путать с туннелями).

## Для ИИ

* `stdout` — только JSON: `{name, path, branch, base, commit}` (create) / `{worktrees:[{name,path,branch,commit,status}]}` (list) / `{name,path,branch,commit,files,dirty}` (status)
* `stderr` — human hint: `hint: worktree 'auth' готов — cd ../milesnear-webapp-auth && opencode`
* Агент запускает `bash` с `workdir: <path>` для работы в конкретном worktree — отдельные сессии не конфликтуют.
* Туннели (`tunnel/run.sh`) — давай разные `--name` на worktree, т.к. `~/.local/state/opencode-tunnel` общий.
* Trello: `BOARD/LIST` из `.trello-project` общие, но можно переопределить `--board/--list` в каждом worktree.

## Ограничения

* Не создаёт worktree если путь уже существует или worktree с таким именем уже зарегистрирован.
* Не удаляет ветку автоматически при `remove` — ветка остаётся, удаляй `git branch -D` если нужно.
