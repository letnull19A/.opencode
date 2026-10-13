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

## Committing

- Коммит — только по явному указанию пользователя. Без просьбы «сделай
  коммит» ничего не коммитить и не пушить.
- Никогда `--force`. Конфликт rebase сам не разруливать — стоп и отчёт
  пользователю.
