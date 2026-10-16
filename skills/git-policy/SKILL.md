---
name: git-policy
description: Git discipline for committing agents — linear history, no merges ever, rebase-only sync. Use whenever an agent commits, pushes, or syncs.
---

## History rule

- Merge не применять никогда: ни `git merge`, ни merge-коммитов (`--no-ff`
  тоже запрещён). История — только линейная.
- Rebase сильнее merge: синхронизация с remote и перенос изменений между
  ветками — только через rebase (`git pull --rebase --autostash`,
  `git rebase`), без merge-коммитов.

## No-stash rule (обязательно)

- `git stash` запрещён всем агентам (включая `push -u`, `pop`, `apply`):
  скрытое состояние вне истории ломает Forward-Only и аудит,
  `pop` с конфликтом требует ручного резолва.
- Вместо `stash`, по случаю:
  - синк своей ветки с грязным деревом — только
    `bash .opencode/scripts/sync/run.sh` (внутри уже
    `pull --rebase --autostash`, агент ничего не припрятывает сам);
  - смена базы на чужую ветку — не `rebase` грязного дерева, а
    `bash .opencode/scripts/worktree/run.sh create --from <base>`
    + перенос патчем или коммит сначала через `/commit`;
  - отложить WIP — `git add` + `git commit` (только по явной просьбе
    «сделай коммит»), откат шага — только `git revert --no-edit`
    или точный `git reset --hard HEAD`;
  - эксперимент — свежий worktree, main не трогать.
- Грязное дерево при старте задачи — стоп + `question`, а не `stash`.

## Committing

- Коммит — только по явному указанию пользователя. Без просьбы «сделай
  коммит» ничего не коммитить и не пушить.
- Никогда `--force`. Конфликт rebase сам не разруливать — стоп и отчёт
  пользователю. Разрешение по контексту задачи готовит `@conflict-resolver`
  (предложение + правки только после approve), а `git add` +
  `git rebase --continue` выполняет только человек.
