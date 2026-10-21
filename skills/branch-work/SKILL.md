---
name: branch-work
description: Опасная работа с ветками только через изолированный worktree — проверка изоляции, Forward-Only, финиш через done. Use whenever an agent must rebase, cherry-pick, bump dependencies or do experimental branch work without touching the main repo.
---

Ты — исполнитель опасной веточной работы. Правило одно: main-репо руками не трогаешь, всё опасное — только в изолированном worktree через скрипт. Смежные скиллы: `worktree-manager` (механика скрипта), `git-recon` (read-only разведка), `git-policy` (linear history, no stash).

## Когда этот скилл (а не main)

- Пересадка на новую базу (rebase --onto), cherry-pick пачки, bump зависимостей, эксперимент, разбор конфликтов, любое «собрать из двух веток».
- Прямая работа в main/dev для этого класса задач запрещена. Dependency-пачка — всегда worktree + строго последовательно (см. `auto` шаг 4b/5/7).

## Создание изоляции (делает родитель, не исполнитель)

1. Зафиксируй `baseCommit` — нижнюю границу отката: `git log --oneline -1` (не `rev-parse`, см. `git-recon`). Залогируй его.
2. `bash .opencode/scripts/worktree/run.sh create --name <slug> --from <baseCommit> --json` (slug `[a-z0-9-]` ≤ 20, напр. `dep-lodash-bump`). Никогда сырой `git worktree add` руками (пропустишь сабмодули/JSON).
3. Передай исполнителю блок `worktree:{path,branch,baseCommit}` + `forwardOnly:{baseCommit}` и `workdir: <path>`.
4. Пакетно: один worktree на связную пачку; общие файлы (compose/env) — только последовательно, не параллельно.

## Как понять, что ты в worktree (проверка изоляции — ПЕРВЫМ шагом, до мутаций)

Первичный способ — один вызов (заменяет пункты 1–4 ручной проверки):
```bash
bash .opencode/scripts/git-recon/run.sh verify --expect-path <worktree.path> --expect-branch <worktree.branch> --json
```
`isolated:true` — работаешь; `isolated:false` — СТОП. Пункты ниже — ручной разбор того же гейта, если скрипта нет в allowlist.

1. **Контракт:** сверь корень своей копии с `workdir`/`worktree.path` из задачи. Нет блока `worktree:{...}` или не совпал — СТОП + `question`, мутаций нет.
2. **Список:** `bash .opencode/scripts/worktree/run.sh list` — твой `path` обязан быть в списке; запомни `branch`/`commit` оттуда.
3. **Признак linked worktree (чтением, не shell):** в worktree `.git` — ФАЙЛ с текстом `gitdir: <main>/.git/worktrees/<name>`, а в main-репо `.git` — КАТАЛОГ. Проверка: `read .git` / `glob .git`. Прочитался файл с `gitdir:` — ты в worktree; каталог — ты в main, СТОП.
4. **Чистота:** `git status --porcelain` пуст. Грязное дерево — СТОП + сначала `/commit`; `stash` запрещён (`git-policy`), не припрятывать.
5. Не прошёл любой пункт — отчёт родителю, никаких правок.

## Первичный способ — scripts/branch-ops (вместо сырых git-операций)
```bash
bash .opencode/scripts/git-recon/run.sh verify --expect-path <worktree.path> --expect-branch <worktree.branch> --json
bash .opencode/scripts/branch-ops/run.sh fetch --remote origin --json
bash .opencode/scripts/branch-ops/run.sh preview --ref <ref> --json
bash .opencode/scripts/branch-ops/run.sh collect --from <ref> --json
bash .opencode/scripts/branch-ops/run.sh sync-base --onto <base> --json
```
- Порядок: verify → fetch → preview → collect/sync-base. Сырые fetch/cherry-pick/rebase руками запрещены — только скрипт (merge запрещён всегда и везде, без исключений на worktree).

## Работа внутри (как не сломать репозиторий)

- Свой `path` не покидаешь: коммиты/правки только внутри `workdir`, checkout в main/dev и `worktree add/remove` руками запрещены — только скрипт.
- **Forward-Only:** граница — `baseCommit`. Дрейф только вперёд `0..N` коммитов (`0` = ничего не вышло — тоже нормально, `-1` — запрещено). Откат шага — только вперёд: `git revert --no-edit` или свежий worktree от `baseCommit`. Запрещены: `reset --hard <цель>`, `push --force`, `merge` (все под `deny`), `stash`.
- Опасное — по одному за раз с проверкой после каждого: bump → check → commit; cherry-pick — по одному коммиту, не пачкой `-n` на 19 штук вслепую.
- Параллель внутри одного worktree при общих файлах (compose/env) запрещена — только последовательно.
- Проверки — раннерами проекта + `scripts/check/run.sh`; статус PR — только `scripts/pr/status-pr.sh` (сырой `gh` к PR запрещён).

## Финиш (только через done)

- `remove` = снести копию, ветка остаётся. `done` = конец жизненного цикла: гейты worktree чист + PR ветки в `MERGED` (+ подтяжка `base` в main без merge-коммитов). Сырой `remove` после принятого PR не чистит `base` — только `done` (механика — `worktree-manager`).
- PR принимает/мержит только человек. Агент доводит до зелёного, отдаёт `PR_URL:` и останавливается.
- Пуш — только `bash .opencode/scripts/push/run.sh` (committed only, never `--force`).

## Правила

- Один tool-call — одна простая команда, без `&&` / `||` / `;` / `|` (см. `git-recon`). Отклонённое не ретраить — в таблицу замен.
- Скилл прав не даёт: нет шаблона в allowlist — просишь родителя/человека, не обходишь.
- Замалчивать несработавшие вызовы запрещено: в отчёт — `cmd/agent/why_chosen/why_failed` (см. контракт `auto`).

## Примеры

```bash
# родитель: изоляция под bump
bash .opencode/scripts/worktree/run.sh create --name dep-lodash-bump --from abc1234 --json
# → {"name":"dep-lodash-bump","path":"../repo-dep-lodash-bump","branch":"dep-lodash-bump",...}

# исполнитель: проверка изоляции первым шагом
bash .opencode/scripts/worktree/run.sh list
git status --porcelain
git log --oneline -5
# read .git → файл с gitdir: → ты в worktree, можно работать

# финиш (из main-репо, не изнутри worktree)
bash .opencode/scripts/worktree/run.sh done --name dep-lodash-bump --json
```
