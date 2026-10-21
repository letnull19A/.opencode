---
name: git-recon
description: Read-only разведка git-истории одиночными разрешёнными командами — без составных цепочек и запрещённых вызовов. Use whenever an agent needs repo state, baseCommit or branch/PR status before planning or delegating.
---

Ты — потребитель read-only git-разведки. Цель — узнать состояние репо, не сломав историю и не получив `Permission denied: shell`.

## Железные правила shell (почему агенты получают отказ)

- Один tool-call — одна простая команда. Запрещены `&&` / `||` / `;` / `|` / `$()` / бэктики и `cd <path> && ...`: составной вызов проверяется по частям и отклоняется целиком, даже если каждая часть по отдельности разрешена.
- Шаблон allowlist требует пробел + `*` (V2-канон `"git log *"`): голые `git log` / `git status` без аргументов НЕ матчится → отказ. Всегда вызывай с аргументом.
- `ask` у субагента без интерактивного клиента = отказ. Отклонённую команду не ретраить дважды — идёшь в таблицу замен ниже.
- Сырые `git merge *`, `push --force`, `reset --hard <цель>`, `stash`, ручные `gh` к PR — под неснимаемым `deny` (linear history, Forward-Only). Обходы запрещены.

## Скрипт вместо сырых команд (первичный способ)
Один вызов заменяет всю ручную разведку и не даёт Permission denied (мутаций нет, stdout — JSON):
```bash
bash .opencode/scripts/git-recon/run.sh status --json
```
```bash
bash .opencode/scripts/git-recon/run.sh log --limit 5 --json
```
```bash
bash .opencode/scripts/git-recon/run.sh base --ref dev --json
```
```bash
bash .opencode/scripts/git-recon/run.sh whereami --json
```
```bash
bash .opencode/scripts/git-recon/run.sh verify --expect-path <path> --expect-branch <b> --json
```
- Сырые команды из раздела ниже — только fallback, если скрипта нет в allowlist (тогда просишь родителя, не обходишь).

## Разрешённый набор разведки

Каждый пункт — ОТДЕЛЬНЫЙ tool-call, не цепочка:

```bash
git status --porcelain
```

```bash
git log --oneline -5
```

```bash
git diff --stat
```

```bash
git diff --name-only
```

```bash
git log --oneline -5 origin/dev
```

```bash
bash .opencode/scripts/pr/status-pr.sh --branch <name>
```

```bash
bash .opencode/scripts/pr/get-pr-url.sh --branch <name>
```

- `status-pr.sh` — ЕДИНСТВЕННЫЙ источник правды о PR (конфликты/checks/reviews/lifecycle). Сырые `gh pr view/list` руками запрещены.
- `git log --oneline -1` — хеш HEAD без запрещённого `rev-parse`. `git log --oneline -1 <ref>` — хеш чужого ref без `rev-parse <ref>`.

## Таблица замен (запрещено → делай так)

- `git rev-parse HEAD` → `git log --oneline -1`
- `git rev-parse <ref>` → `git log --oneline -1 <ref>`
- `git branch -a | head -50` → `git log --oneline -5 --all --decorate` (ветки видны в decorate, без `branch` и без пайпа)
- `git branch --show-current` → `git status --branch --porcelain` (матчится под `git status *`, в отличие от `branch`)
- `git merge-base A B` → `git log --oneline -5 A` + `git log --oneline -5 B` (линейная проверка ancestry глазами, без `merge-base`)
- `git fetch ...` → НЕ делать в разведке. Работай со stale refs; fetch/sync — только родитель или человек через `bash .opencode/scripts/sync/run.sh`
- `git merge --no-ff ...` → НИКОГДА (deny, linear history). Отставание от базы — `bash .opencode/scripts/sync/rebase.sh --onto <base>`, конфликт по содержанию — `@conflict-resolver`
- `A && B` / `A; B` / `A | head` → N отдельных вызовов; вместо `| head` — флаги `-5` / `--limit` или авто-транкейт вывода
- `gh pr view/list/create` руками → только `scripts/pr/*` (`status-pr.sh`, `list-prs.sh`, `get-pr-url.sh`)
- `git push` руками → только `bash .opencode/scripts/push/run.sh` (pushes committed commits only, never `--force`)

## Правила

- После первого `Permission denied` — в таблицу замен, не повтор.
- Нет данных (stale ref, unknown) — спроси `question`, не выдумывай хеш/baseCommit.
- Скилл прав не даёт: если твоего allowlist-шаблона (`git log *` / `git status *` / `git diff *`, скрипты `pr/*`) нет — попроси родителя/человека, не обходи.
- Мутаций нет — только чтение.
