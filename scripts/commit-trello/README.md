# commit-trello — связь коммитов ↔ Trello-карточек по трейлерам

Машинно-парсибельный формат коммитов (см. `skills/commit/SKILL.md`):

```
Trello: https://trello.com/c/<SHORT>
Closes: https://trello.com/c/<SHORT>
```

* `Trello:` — связь (может быть несколько строк). Парсер `^Trello:\s*https?://trello\.com/c/(\w+)`.
* `Closes:` (синоним `Fixes:`) — маркер закрытия → автоперемещение в `Done`.

## Использование (из корня проекта)

```bash
# все коммиты с Trello за последний год
bash .opencode/scripts/commit-trello/run.sh --all --limit 20

# коммиты по карточке (любой формат: URL / shortLink / id)
bash .opencode/scripts/commit-trello/run.sh --card https://trello.com/c/gFZbZhni
bash .opencode/scripts/commit-trello/run.sh --card gFZbZhni --limit 10 --json

# трейлеры конкретного коммита
bash .opencode/scripts/commit-trello/run.sh --commit 5b7744f --json
```

Вывод — только JSON на `stdout` (для ИИ), `hint` на `stderr` если без `--json`. Поля:
`mode: card|commit|all`, `commits: [{hash, short, subject, date, trello[], closes[]}]`.

Для людей: `git log --grep=Trello --oneline` или `git show <hash>` — трейлеры внизу после пустой строки (формат `git interpret-trailers`).
