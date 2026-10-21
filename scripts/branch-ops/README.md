# branch-ops — опасные веточные операции (только worktree, детерминированно, с JSON)

Зачем: `fetch` / `cherry-pick` / `rebase` руками — главный способ снести чужую
историю из main-репо. Этот скрипт разрешает их только внутри изолированного
worktree, по одному детерминированному пути, с гейтом изоляции первым шагом
и JSON на stdout (как `git-recon` / `worktree`).

## Команды

```bash
# сверить remote-состояние (только голый fetch, без refspec/--force/--prune)
bash .opencode/scripts/branch-ops/run.sh fetch --remote origin --json

# read-only прогноз вливания R в HEAD (already_merged / fast_forward / эвристика файлов)
bash .opencode/scripts/branch-ops/run.sh preview --ref <ref> --json
bash .opencode/scripts/branch-ops/run.sh preview --ref <ref> --base <B> --json

# поштучный cherry-pick -x уникальных коммитов R; конфликт — стоп exit 2
bash .opencode/scripts/branch-ops/run.sh collect --from <ref> --json
# после ручного разрешения конфликта:
bash .opencode/scripts/branch-ops/run.sh collect --continue --json
# scoped undo незавершённого cherry-pick:
bash .opencode/scripts/branch-ops/run.sh collect --abort --json

# пересадка текущей ветки на свежую базу (делегация sync/rebase.sh --onto)
bash .opencode/scripts/branch-ops/run.sh sync-base --onto <base> --json
```

Порядок: `verify` → `fetch` → `preview` → `collect` / `sync-base`.
Сырые `fetch` / `cherry-pick` / `rebase` руками запрещены — только скрипт.

## Связь со скиллами

- `branch-work` — первичный способ работы (изоляция, Forward-Only, финиш через `done`).
- `git-recon` — read-only разведка; `verify` — гейт, который `collect`/`sync-base`
  зовут первым шагом (`isolated:false` → JSON + exit 1, мутаций нет).
- `git-policy` — linear history, no stash: дерево грязное → сначала `/commit`.
- `worktree-manager` — механика `worktree create/list/done`; финиш только через `done`.

## Что запрещено

- `merge` / `push` / `reset --hard` / `stash` — нет ни в каком виде, без исключений
  на worktree. Откат шага — только вперёд (`git revert --no-edit`) или свежий
  worktree от `baseCommit`.
- Конфликт (`collect`, `sync-base`) = стоп-отчёт exit 2: состояние оставить для
  разбора, дальше `@conflict-resolver` + человек (`git add` + `--continue`),
  либо `collect --abort` / `git rebase --abort`. Самолечения нет.
- `preview` честно помечает `heuristic:true`: пересечение файлов — прогноз,
  а не гарантия отсутствия конфликта.
