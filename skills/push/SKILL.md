---
name: push
description: Send ONLY committed commits via .opencode/scripts/push/run.sh (never add/commit/force). Use when the user explicitly asks /push — uncommitted files physically cannot leave the machine.
---

Скрипт отправляет только зафиксированные коммиты текущей ветки: здесь НЕТ и никогда не будет `add`/`commit`/`stash`/`checkout`/`reset`/`--force`/`--delete`. Грязное дерево — warning, не блокер: незакоммиченное остаётся локально.

## Когда вызывать

- Только по явной просьбе (`/push`, `{"push": true}` от caller) после зелёных проверок. Сам `push` не выдумываешь.
- Перед пушем: `scripts/check/run.sh --json` чисто + PR-статус (`scripts/pr/status-pr.sh`) если ветка уже в PR.

## Рецепты

```bash
bash .opencode/scripts/push/run.sh
```

```bash
bash .opencode/scripts/push/run.sh --remote <name> --dry-run
```

- `--dry-run` — что бы уехало, без отправки.
- После пуша — обязательно `bash .opencode/scripts/pr/get-pr-url.sh [--branch <name>]` и ретрансляция `PR_URL:` (или `PR_URL: none` + как создать).

## Правила

- `git push` руками запрещён; `--force`/`-f` — неснимаемый `deny` (linear history). Обход запрещён.
- Упал `push` (нет remote, detached HEAD, rejected) — показываешь вывод + диагноз, `pull --rebase` сам не делаешь (это `sync`, решает человек/caller).
- Скилл прав не даёт: нет `scripts/push/*` в allowlist — просишь родителя/человека.
