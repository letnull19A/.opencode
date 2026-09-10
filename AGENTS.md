# AGENTS.md — portable `.opencode` pack

This repo IS the opencode config. It is cloned as `.opencode/` into consumer
projects, so paths in agent/skill prompts (`.opencode/scripts/...`) assume
CWD = consumer repo root, not this repo root.

issue_provider: github

## Never do

- Do NOT add `*.md` at repo root (e.g. `README.md`). Opencode registers root
  `*.md` as agents (see git log `0e60eb1`). Only `AGENTS.md` lives at root;
  docs go under `scripts/<name>/README.md` or `AGENTS.md.snippet`.
- Runner agents/skills (`screenshot-report`, `tunnel-manager`) never edit code
  or their own scripts. On non-zero exit paste last ~15 lines + relevant log,
  do not fix the script.
- Issue pipeline: never call `create-issue.sh` directly, never run `create`
  without `preview` + explicit user "yes". Only `@issue-writer` thinks (LLM);
  everything after it is deterministic scripts.
- Push pipeline (внутри `/push`): never `git add` / `git commit` / manual
  `git push` / `--force`. Only `bash .opencode/scripts/push/run.sh` — it pushes
  committed commits only, uncommitted files always stay local.
- Commit pipeline (внутри `/commit`): коммиты создаёт только агент через
  скилл `commit` (атомарно, Conventional Commits, план + явное «да»).
  Никогда `push` / `--force` / коммит секретов. Вне `/commit` агент сам
  `git commit` не делает.
- Sync pipeline (внутри `/sync`): never `git pull` / `git fetch` / `git rebase`
  / `git merge` / `git stash` вручную / `--force`. Only
  `bash .opencode/scripts/sync/run.sh` — он тянет только через
  `pull --rebase --autostash`, без merge-коммитов; конфликт rebase агент
  сам не разруливает, а отдаёт пользователю.
- Trello-task pipeline (внутри `/new-task` / `@trello-task`): думает только
  агент `trello-task`; Trello API касаются только скрипты
  (`scripts/trello-task/`), агент сам curl к api.trello.com не делает.
  Создание/перемещение карточки — только после черновика + явного «да»;
  тег проекта — только из `.trello-project` (NAME), имена досок/листов
  не выдумываются.

## Layout (ownership)

- `agent/` — opencode subagents (`issue-writer`, `screenshot-report`,
  `component-builder`, `refactor`, `trello-task`). `component-builder` targets
  the external `@web2bizz/ui` kit, not this repo — don't apply its rules here.
  `trello-task` — `mode: all` (и primary, и subagent), думает за весь
  trello-task пайплайн, права зажаты (bash только на `scripts/trello-task/*`).
- `skills/tunnel-manager/SKILL.md` — preview-tunnel runner (wraps
  `scripts/tunnel/`).
- `skills/commit/SKILL.md` — стратегия атомарных коммитов (Conventional
  Commits, группировка по интентам, план + явное «да», без push).
- `skills/trello-task/SKILL.md` — качественное использование trello-task
  скриптов любым агентом (рецепты init/boards/lists/create/move, точные
  имена, мутации только после «да»); `@trello-task` остаётся
  предпочтительным исполнителем.
- `scripts/issue-writer/` — `schema/issue.schema.json` (LLM contract) +
  `validate-issue-data.py` → `detect-provider.sh` → `render-issue.py` →
  `create-issue.sh`, glued by `orchestrate.sh`.
- `scripts/screenshot-report/` — `run.sh` → `capture.js` → `report.js` →
  `send.js`; viewports fixed in `config/viewports.js`; per-script `package.json`.
- `scripts/tunnel/` — `run.sh` → `tunnel.js` (localtunnel/loca.lt),
  per-script `package.json`. State in `~/.local/state/opencode-tunnel/<name>.json`.
- `commands/` — custom slash-commands (`push.md` → `/push`, thin runner over
  `scripts/push/run.sh`, no git thinking in the agent; `commit.md` → `/commit`,
  thinking command over skill `commit`: atomic Conventional Commits, no push;
  `sync.md` → `/sync`, thin runner over `scripts/sync/run.sh`, no git thinking;
  `new-task.md` → `/new-task`, delegates to `trello-task` subagent).
- `scripts/push/` — `run.sh` (deterministic `git push` of committed commits
  only; no `add`/`commit`/`--force`; see `scripts/push/README.md`).
- `scripts/sync/` — `run.sh` (deterministic `git pull --rebase --autostash`
  of current branch; no `merge`/`--force`; see `scripts/sync/README.md`).
- `scripts/trello-task/` — `init.sh` (project tag → `.trello-project`) +
  `boards.sh` / `lists.sh` (discovery) + `create.sh` (card with NAME label)
  + `move.sh` (card → target list via PUT `idList`, `--dry-run` без мутаций),
  всё via Trello REST; агент думает, скрипты исполняют; see
  `scripts/trello-task/README.md`).
- `opencode.json` — `default_agent: build`, only pre-approved bash is
  `bash .opencode/scripts/tunnel/run.sh*` +
  `bash .opencode/scripts/push/run.sh*` +
  `bash .opencode/scripts/sync/run.sh*`; `mcp.trello` (`npx -y
  @delorenj/mcp-server-trello`, ключи только через `{env:TRELLO_API_KEY}` /
  `{env:TRELLO_TOKEN}`) + `mcp.context7` (remote `https://mcp.context7.com/mcp`,
  ключ опционален через `{env:CONTEXT7_API_KEY}`; секреты в репозиторий
  не коммитить). Root `package.json`
  has only `@opencode-ai/plugin`, no scripts.

## Commands (run from consumer repo root)

No root build/test/lint. Verify per script:

```bash
# issue-writer: subagent emits JSON only, then:
echo '<json>' | python3 .opencode/scripts/issue-writer/validate-issue-data.py > /tmp/issue.json  # needs pip install jsonschema
bash .opencode/scripts/issue-writer/orchestrate.sh preview /tmp/issue.json
bash .opencode/scripts/issue-writer/orchestrate.sh create /tmp/issue.json "label1,label2"  # only after user confirms
```

```bash
# screenshot-report (needs --base-url; first run: npm install + playwright chromium, needs network):
bash .opencode/scripts/screenshot-report/run.sh --base-url "<url>" [--pages .opencode/scripts/screenshot-report/pages.json] [--method local|telegram|webhook|s3]
# pages file shape: [{ "id": "...", "path": "/route" }]; default pages.example.json; viewports only via config/viewports.js
# outputs to scripts/screenshot-report/out/ (gitignored); copy .env.example → .env for telegram/webhook/s3
```

```bash
# tunnel (start dev server first; start is idempotent; default TTL 3600s):
bash .opencode/scripts/tunnel/run.sh start --port <port> [--name <n>] [--ttl <s>]
bash .opencode/scripts/tunnel/run.sh status  # or: url [--name <n>]
bash .opencode/scripts/tunnel/run.sh restart --port <port>  # new random URL
bash .opencode/scripts/tunnel/run.sh kill [--name <n> | --all]
# ALWAYS relay PREVIEW_URL + note: loca.lt reminder page password = PUBLIC_IP. Debug via ~/.local/state/opencode-tunnel/<name>.log
```

```bash
# push (agent runs this ONLY via /push; pushes committed commits only, never add/commit/--force):
bash .opencode/scripts/push/run.sh [--remote <name>] [--dry-run]
# dirty tree is a warning, not a blocker: uncommitted files stay local, only commits are pushed.
```

```bash
# sync (agent runs this ONLY via /sync; rebase-only, never merge/--force):
bash .opencode/scripts/sync/run.sh [--remote <name>] [--dry-run]
# dirty tree is autostashed and restored automatically, no merge commits; rebase conflict is a stop-and-report, never auto-resolved.
```

```bash
# commit (agent runs this ONLY via /commit; skill `commit` thinks, then acts):
# /commit [<hint>] — анализ diff, план атомарных коммитов, явное «да», затем
# точечный git add <paths> + git commit по группам. Никогда push/--force.
# Отправка — только отдельным /push.
```

```bash
# trello-task (agent runs this ONLY via /new-task or @trello-task; scripts do Trello API):
bash .opencode/scripts/trello-task/init.sh [--name <tag>] [--force]   # тег проекта → .trello-project (NAME)
bash .opencode/scripts/trello-task/boards.sh                          # мои доски (точные имена)
bash .opencode/scripts/trello-task/lists.sh --board "<name>"          # листы доски
bash .opencode/scripts/trello-task/create.sh --title "<t>" [--board "<b>"] [--list "<l>"] [--desc "<d>"] [--save-defaults]
bash .opencode/scripts/trello-task/move.sh (--id <id> | --url <url> | --card "<name>") --list "<target>" [--to-board "<b>"] [--dry-run]
# карточка — только после черновика + явного «да»; нужны TRELLO_API_KEY/TRELLO_TOKEN в env.
```

## Version / env gotchas

- Agent dir is `.opencode/agent/` here, but some opencode versions expect
  `.opencode/agents/` (plural). Check version docs before renaming.
- `permission:` frontmatter in `agent/*.md` is V1 syntax. On V2 config move
  rules to `opencode.json` `permissions: [...]` with `resource` patterns.
- `issue-writer` agent is locked down (`edit: deny`, bash allowlist: only
  `git diff/log/show`, `cat`, `validate-issue-data.py`). Do not broaden.
- `create-issue.sh` needs external CLIs: `gh` / `glab` / `tea`; bitbucket goes
  via curl + `BITBUCKET_WORKSPACE/SLUG/USERNAME/APP_PASSWORD` env.
- `detect-provider.sh` reads `^issue_provider:` from consumer `AGENTS.md`;
  autodetect only works for `github.com|gitlab.com|bitbucket.org` — self-hosted
  requires the explicit field.
- `mcp.trello` needs env keys, otherwise its tools fail at startup:
  `TRELLO_API_KEY` (from `https://trello.com/app-key`) +
  `TRELLO_TOKEN` (generate on the same page, scope: read/write).
  Set via `export TRELLO_API_KEY=... TRELLO_TOKEN=...` or `.env`
  (never commit real values — `opencode.json` references only `{env:...}`).
- `mcp.context7` works without a key (lower rate limits); with a free key
  from `https://context7.com` limits are higher:
  `export CONTEXT7_API_KEY=...` (also only via `{env:...}`, never committed).
- `scripts/trello-task/*` intentionally NOT in `opencode.json` bash allowlist:
  creating external Trello cards is a side effect — first run asks approval
  via opencode itself (on top of the agent's draft + «да» rule).
