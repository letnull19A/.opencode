---
name: sync
description: Pull remote into the current branch ONLY via .opencode/scripts/sync/run.sh (pull --rebase --autostash, never merge/force). Use when a branch fell behind base — dirty tree is autostashed, conflicts go to @conflict-resolver.
---

Агент не думает про git — вызывает ровно одну команду и ретранслирует вывод. Скрипт умеет только rebase-синк текущей ветки: здесь НЕТ и никогда не будет `merge`, `--force`, `reset --hard`, `checkout .`, `clean`, ручного `stash`, `push`.

## Когда вызывать

- Ветка отстала от базы (`behind > 0` по `git-recon`), перед PR-верификацией, по команде `/sync` или `@auto`.
- Сырые `git pull`/`git fetch`/`git rebase`/`git merge` руками — запрещены (linear history, Forward-Only).

## Рецепты

```bash
bash .opencode/scripts/sync/run.sh
```

```bash
bash .opencode/scripts/sync/run.sh --remote <name> --dry-run
```

```bash
bash .opencode/scripts/sync/rebase.sh --onto <base>
```

- `--dry-run` — только проверка (что бы подтянулось), без изменений.
- Незафиксированные изменения переживают синк через `--autostash` и возвращаются сами — ничего не припрятываешь.
- Конфликт rebase — стоп, сам не разруливаешь: `subagent` → `@conflict-resolver`. Сырой `git rebase --continue/--abort` запрещён.

## Правила

- Один вызов — одна простая команда, без `&&`/`||`/`;`. `cd` не используешь — каталог задаёт `workdir`/`worktree` от caller.
- Провал (нет remote, detached HEAD, конфликт) — ретранслируешь вывод + диагноз, не импровизируешь fetch/merge.
- Скилл прав не даёт: нет `scripts/sync/*` в allowlist — просишь родителя/человека.
