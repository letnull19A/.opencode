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
  скилл `commit` (атомарно, Conventional Commits, сразу по явной просьбе
  без «да»; вопросы только при неоднозначности/секретах).
  Никогда `push` / `--force` / коммит секретов. Вне `/commit` агент
  коммитит только по прямому указанию пользователя («сделай коммит»).
- Sync pipeline (внутри `/sync`): never `git pull` / `git fetch` / `git rebase`
  / `git merge` / `git stash` вручную / `--force`. Only
  `bash .opencode/scripts/sync/run.sh` — он тянет только через
  `pull --rebase --autostash`, без merge-коммитов; конфликт rebase агент
  сам не разруливает, а отдаёт пользователю.
- Task-manager pipeline (внутри `/new-task` / `@task-manager`): думает только
  оркестратор `task-manager`, аудит — сабагент `task-audit` по его делегированию;
  Trello API касаются только скрипты
  (`scripts/task-manager/`), агенты сами curl к api.trello.com не делают.
  Создание/перемещение карточки — сразу по просьбе пользователя, без
  черновика и «да» (вопросы только про недостающие данные);
  задача — только по строгому формату (заголовок + Контекст/Что сделать/
  Критерии приёмки/Связи, неполную не создавать);
  подзадачи — чек-листом (`checklist.sh`), зависимости — строкой
  `Blocked by:` (нативного графа в Trello нет);
  тег проекта — только из `.devbox-project` (NAME), имена досок/листов
  не выдумываются; аудит — чтение с возвратом строго JSON.
- React-fix pipeline (внутри `/fix` / `@react-fix`): классы в коде ищет
  только `scripts/react-fix/find-class.sh` (сырой grep/rg по классам
  запрещён); пока точно не выяснено «что менять + где» — никаких `edit`,
  агент спрашивает пользователя; правит ровно подтверждённое, чеклист —
  по одному «да» на пункт.
- Module pipeline (внутри `/new-module`): стратегию (add/update/delete/decompose,
  приоритет decompose>delete>update>add) и домен (только по файлам проекта)
  выбирает агент по скиллу `module-develop`; тесты — делегирование
  `@unit-test`, implementation для update/delete/decompose — `@refactor`,
  add — сам `build`; правки — после компактного плана + явного «да»;
  верификация — реальным раннером, возвраты по `PIPELINE_MAX_RETRIES`;
  git агент не трогает (коммиты — `/commit`, пуш — `/push`).
- Component-design pipeline (при планировании/проектировании React-компонента):
  дизайн думает только `@component-builder` (read-only, `mode: all`) —
  primary-агент, включая Plan, компонент сам не проектирует, а делегирует
  дизайн ему; агент возвращает в чат дерево компонентов, ответственности,
  props-контракты и разбиение большого компонента на мелкие; UI-кит не
  навязывает; код не пишет — реализация остаётся за `build`/`@refactor`,
  и до готового дизайна реализацию не начинают.

## Layout (ownership)

- `agent/` — opencode subagents (`issue-writer`, `screenshot-report`,
  `component-builder`, `refactor`, `task-manager`, `task-audit`, `react-fix`, `unit-test`).
  `component-builder` — `mode: all`, read-only проектировщик React-компонентов
  (edit/bash запрещены): выдаёт в чат дерево компонентов, ответственности,
  props-контракты и декомпозицию большого компонента на мелкие, UI-кит
  не навязывает, код не пишет.
  `task-manager` — `mode: all` (и primary, и subagent), думает за весь
  task-manager пайплайн, права зажаты (bash только на `scripts/task-manager/*`).
  `task-audit` — `mode: subagent`, только аудит по делегированию `task-manager`,
  возврат строго JSON по `scripts/task-manager/schema/audit.schema.json`.
  `react-fix` — тоже `mode: all`; думает за весь react-fix пайплайн
  (поиск классов — только скриптом, правки — только после выясненного
  «что менять», см. `scripts/react-fix/README.md`).
  `unit-test` — тоже `mode: all`; пишет юнит-тесты под любой фреймворк,
  синтаксис фреймворка — только из Context7 MCP (по памяти запрещено).
- `skills/tunnel-manager/SKILL.md` — preview-tunnel runner (wraps
  `scripts/tunnel/`).
- `skills/ci/SKILL.md` — vendor-lock-free GitHub Actions CI/CD (требования→исполнение): `@ci` (`mode:all`) опрашивает пользователя (type/registry/image/platforms/cache/deploy) → `task → @ci-runner` (`hidden:subagent`) скаффолдит `scripts/ci/scaffold.sh --type ci|docker|all` из `scripts/ci/templates/*.yml` → `.github/workflows/`; `workflows.sh status|logs` — read-only; registry-agnostic (`vars.DOCKER_REGISTRY`/`vars.DOCKER_IMAGE`/`secrets.REGISTRY_*` + `GITHUB_TOKEN` fallback), buildx + gha cache, без cloud-экшенов.
- `skills/commit/SKILL.md` — стратегия атомарных коммитов (Conventional
  Commits, группировка по интентам, сразу по явной просьбе без «да», без push).
- `skills/task-manager/SKILL.md` — качественное использование task-manager
  скриптов любым агентом (рецепты init/boards/lists/create/move/checklist/audit,
  строгий формат задачи, точные имена, мутации — сразу по просьбе, без «да»);
  `@task-manager` остаётся предпочтительным исполнителем.
- `skills/react-fix/SKILL.md` — качественное использование react-fix
  скрипта любым агентом (рецепт find-class → вопрос → точечная правка,
  разбор таблицы, BEM/camelCase-нюансы); `@react-fix` остаётся
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
  `new-task.md` → `/new-task`, delegates to `task-manager` subagent;
  `fix.md` → `/fix`, delegates to `react-fix` subagent;
  `new-module.md` → `/new-module`, thinking over skill `module-develop`,
  orchestrated by `build` (делегирует `@unit-test`/`@refactor`).
- `scripts/push/` — `run.sh` (deterministic `git push` of committed commits
  only; no `add`/`commit`/`--force`; see `scripts/push/README.md`).
- `scripts/react-fix/` — `find-class.sh` (поиск CSS-класса в tsx/css →
  таблица `FILE|LINE|KIND|TEXT` для ИИ; точное имя + BEM-дети, без
  подстрок; read-only; см. `scripts/react-fix/README.md`).
- `scripts/sync/` — `run.sh` (deterministic `git pull --rebase --autostash`
  of current branch; no `merge`/`--force`; see `scripts/sync/README.md`).
- `scripts/task-manager/` — `init.sh` (project tag → `.devbox-project`) +
  `boards.sh` / `lists.sh` (discovery) + `create.sh` (card with NAME label)
  + `move.sh` (card → target list via PUT `idList`, `--dry-run` без мутаций)
  + `checklist.sh` (подзадачи чек-листом: create/add-item/complete/show JSON)
  + `audit.sh` (read-only board audit → JSON для `task-audit`, парсит
  `Blocked by:` в `blocked_by`) + `schema/audit.schema.json` (AI-контракт),
  всё via Trello REST; агент думает, скрипты исполняют; see
  `scripts/task-manager/README.md`).
- `opencode.json` — `default_agent: build`, only pre-approved bash is
  `bash .opencode/scripts/tunnel/run.sh*` +
  `bash .opencode/scripts/push/run.sh*` +
  `bash .opencode/scripts/sync/run.sh*` +
  `bash .opencode/scripts/ci/*` + `bun workflows/*` +
  `bash .opencode/scripts/react-fix/*` (read-only class search); `mcp.trello` (`npx -y
  @delorenj/mcp-server-trello`, ключи только через `{env:TRELLO_API_KEY}` /
  `{env:TRELLO_TOKEN}`) + `mcp.context7` (remote `https://mcp.context7.com/mcp`,
  ключ опционален через `{env:CONTEXT7_API_KEY}`) + `mcp.dokploy`
  (`npx -y @dokploy/mcp`, `DOKPLOY_URL` + `DOKPLOY_API_KEY` только через
  `{env:...}`, пресет `minimal` против 508 инструментов; секреты
  в репозиторий не коммитить). Root `package.json`
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
# /commit [<hint>] — анализ diff, сразу по явной просьбе без «да», затем
# точечный git add <paths> + git commit по группам. Никогда push/--force.
# Отправка — только отдельным /push.
```

```bash
# task-manager (agent runs this ONLY via /new-task or @task-manager; scripts do Trello API):
bash .opencode/scripts/task-manager/init.sh [--name <tag>] [--force]   # тег проекта → .devbox-project (NAME)
bash .opencode/scripts/task-manager/boards.sh                          # мои доски (точные имена)
bash .opencode/scripts/task-manager/lists.sh --board "<name>"          # листы доски
bash .opencode/scripts/task-manager/create.sh --title "<t>" [--board "<b>"] [--list "<l>"] [--desc "<d>"] [--save-defaults]
bash .opencode/scripts/task-manager/move.sh (--id <id> | --url <url> | --card "<name>") --list "<target>" [--to-board "<b>"] [--dry-run]
bash .opencode/scripts/task-manager/checklist.sh --card "<name>" --create "Подзадачи" --items "Шаг 1;Шаг 2"
bash .opencode/scripts/task-manager/audit.sh --board "<name>" [--tag "<t>" | --all]  # JSON для task-audit
# карточка — сразу по просьбе пользователя, без «да»; нужны TRELLO_API_KEY/TRELLO_TOKEN в env.
```

```bash
# react-fix (agent runs this ONLY via /fix or @react-fix; script finds, agent asks, then edits):
bash .opencode/scripts/react-fix/find-class.sh --class journal [--class header] [--root src]
# → таблица FILE|LINE|KIND|TEXT → если неясно что/где править — вопрос пользователю (без edit!) →
# → точечная правка только подтверждённого → проверка командами consumer-проекта.
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
- `scripts/task-manager/*` IS in `opencode.json` bash allowlist for autonomous
  work: creating Trello cards is a side effect, but user explicitly enabled
  auto-approval (agent-level «да» убран: просьба уже приказ, permission-prompt
  тоже отключён).
- `scripts/react-fix/*` IS in `opencode.json` bash allowlist: `find-class.sh`
  is read-only (stdout only, no mutations), so class search never asks
  for approval; edits themselves stay behind the agent's «что менять» rule.
- `mcp.dokploy` needs both env vars (self-hosted, URL у каждого свой):
  `DOKPLOY_URL=https://<твой-докплей>` + `DOKPLOY_API_KEY` (Dokploy Settings →
  API Keys). Preset `minimal` грузит мало инструментов против всех 508;
  расширить: `all`/`core`/`deploy`/`databases`/`git` или точечно через
  `DOKPLOY_ENABLED_TAGS=project,application,postgres`.
  (also only via `{env:...}`, never committed).
