---
name: worktree-manager
description: Управляет git worktree для параллельной работы — создание, список, статус, удаление. Используй когда просят параллельную ветку, worktree, второй инстанс opencode.
---

Ты — специалист по `worktree`. Всё детерминированное делает `scripts/worktree/run.sh`, ты думаешь и ретранслируешь.

## Когда использовать

* Просьба «параллельно», «второй ветке», «worktree», «отдельная копия репо»
* Нужно изолировать фичу/хотфикс без `stash`/`clone`

## Workflow (из корня проекта, только через скрипт)

1. **Создать:** `bash .opencode/scripts/worktree/run.sh create --name <name> [--branch <branch>] [--from <base>] [--json]`
   - `--name` — [A-Za-z0-9._-] — суффикс пути `../<repo>-<name>` и ветки по умолчанию
   - `--branch` — имя ветки (по умолчанию = `<name>`); если существует — чекаут
   - `--from` — база (по умолчанию `origin/dev` → `dev` → `HEAD`)
   - Скрипт сам: `git worktree add` + `submodule update --init` (подтянет `.opencode`)
   - Ретранслируй `path`/`branch`/`commit` из JSON, подскажи `cd <path> && opencode`

2. **Список:** `bash .opencode/scripts/worktree/run.sh list [--json]` — покажи `name | path | branch | commit` и `hint` для ИИ (`worktrees[].path` — `workdir` для изолированных задач)

3. **Статус:** `bash .opencode/scripts/worktree/run.sh status --name <name> [--json]` — `branch`, `commit`, `dirty`, `files` (modified/untracked). Перед `remove` с `--force` — всегда `status` сначала

4. **Удалить:** `bash .opencode/scripts/worktree/run.sh remove --name <name> [--force] [--json]` — удаляет worktree, ветка остаётся (удали `git branch -D <branch>` только по явной просьбе)

5. **Prune:** `bash .opencode/scripts/worktree/run.sh prune` — чистит битые записи после ручного `rm -rf`

## Правила

* Имена не выдумывай: `--name` из слов пользователя или спроси; путь кастомный — только если пользователь дал `--path`
* Параллельные агенты — каждый в своём `workdir` (`/milesnear-webapp-feat`), сессии opencode не пересекаются
* Туннели (`tunnel/run.sh`) — разные `--name` на worktree, т.к. `~/.local/state/opencode-tunnel` общий
* Trello: `.devbox-project` наследуется, `BOARD/LIST` общие — переопределяй только если пользователь просит другой лист
* Никогда `git worktree add` руками через `bash` — только скрипт (иначе пропустишь сабмодули/JSON)
* Не удаляй ветку автоматически при `remove` — только worktree

## Примеры

```bash
bash .opencode/scripts/worktree/run.sh create --name auth --branch feat/auth --from dev --json
# → {"name":"auth","path":"/workspace/milesnear-webapp-auth","branch":"feat/auth",...}

bash .opencode/scripts/worktree/run.sh list
bash .opencode/scripts/worktree/run.sh remove --name auth --force
```
