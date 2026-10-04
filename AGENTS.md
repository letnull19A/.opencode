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
- PR URL rule (все git-операции): агент гарантированно отдаёт кликабельную
  ссылку на PR. При создании — только через
  `bash .opencode/scripts/pr/create-pr.sh --title "<title>" --json /tmp/pr.json --base <base>`
  и ретрансляция строки `PR_URL: <url>` из stdout. При любом упоминании PR
  и после `/push` / `/sync` / `/commit` — обязательно
  `bash .opencode/scripts/pr/get-pr-url.sh` и ретрансляция `PR_URL:`
  (или `PR_URL: none` + как создать). Ссылку не выдумывать, ответ про PR
  без вызова скрипта запрещён.
- PR body rule: агент НЕ пишет текст PR свободной формой. Только JSON по
  `scripts/pr/schema/pr.schema.json` → `validate-pr-data.py` →
  `create-pr.sh --json` (скрипт сам рендерит через `render-pr.py`:
  `Summary` → `Changes` → `How to verify` → `Notes`). `--body` —
  только для исключений.
- PR status rule: перед ЛЮБЫМ ответом о состоянии PR (конфликты, checks,
  reviews, готов ли к мержу) агент выполняет
  `bash .opencode/scripts/pr/status-pr.sh [--branch <name>]` и отвечает
  СТРОГО по его выводу, а не по памяти. `CONFLICTS: unknown` означает
  «не знаю», а не «конфликтов нет» — отсутствие конфликтов утверждать
  только при `CONFLICTS: no`. Если скрипт упал или вернул unknown —
  честно сказать и показать команду проверки, а не выдумывать статус.
- PR merge rule: агент НИКОГДА сам не принимает/не мержит PR — ни через
  `gh pr merge`, `glab mr merge`, `tea * merge`, REST `/merge`, ни через
  `--auto` и `gh api .../merge`. PR принимает только человек (в UI или
  своим CLI). Механически запрещено в `opencode.json` (`deny`, работает
  даже в auto-режиме). Если просят «замержи» — не мержить, а отдать
  человеку `PR_URL:` + свежий `status-pr.sh` и команду для ручного мержа.
- DESIGN.md rule (только UI: веб и мобилки): `DESIGN.md` в корне проекта,
  владелец — человек; агентам всех отделов файл — только для чтения
  (UI-ядро `react-*` — строгий read-only, см. Departments). Агент за
  UI-задачей перед работой делает `init.sh --check`, если файла нет —
  `init.sh` + первичное заполнение разделов по коду/опросу; контекст
  правил берёт программно через
  `bash .opencode/scripts/design/context.sh` (исполняющий агент;
  read-only сабагенты без bash читают `DESIGN.md` напрямую) и работает
  строго по нему (токены/компоненты/конвенции); противоречие — вопрос
  пользователю, а не тихий отход. Нужны изменения (токен/компонент/
  конвенция) — агент показывает человеку точный патч (секция → строки);
  вносит только владелец, затем approve → коммит. Обновление разделов
  и журнала после задачи — тоже за владельцем, по предложению агента.
  Backend/infra-агенты файл игнорируют.
- Design-guard rule (коммиты UI): ничто UI не попадает в коммит без
  проверки — перед `git add` исполняющий агент прогоняет
  `bash .opencode/scripts/design/guard.sh` (только незакоммиченные
  изменения). Error-нарушения — стоп и явный approve человека;
  без approve коммита нет. На `design-not-updated` агент отдаёт точные
  предлагаемые правки `DESIGN.md`; вносит их человек, затем approve →
  коммит. Проверяльщик здесь — человек.
- Security rule (все коммиты, фронт + бэк): вход валидируется на границе
  (API — schema до логики, формы — тем же schemas), выход сериализуется
  через schemas, sinks (`innerHTML`/`eval`/`shell=True`) и конкатенация
  в SQL — запрет. Перед `git add` каждого коммита — обязательно
  `bash .opencode/scripts/security/guard.sh` (только незакоммиченные
  изменения). Error — стоп + approve человека; разбор нарушений можно
  делегировать `@security` через `task` (он предложит validator-патчи,
  код не правит). Конвенция — `scripts/security/README.md`.
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
  тег проекта — только из `.devbox` (NAME), имена досок/листов
  не выдумываются; аудит — чтение с возвратом строго JSON.
  Конфиг-миграция: legacy `.devbox-project` / `.trello-project` → `.devbox`
  первым шагом (`bash .opencode/scripts/task-manager/migrate.sh`,
  авто-миграция также в `_common.sh`); `COMMENTS_DETAILS` вне `0..9` = стоп.
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
  дизайн думает только `@component-builder` (read-only hidden subagent) —
  включая Plan, компонент сам не проектирует, а делегирует
  дизайн ему; агент возвращает в чат дерево компонентов, ответственности,
  props-контракты и разбиение большого компонента на мелкие; UI-кит не
  навязывает; код не пишет — реализация остаётся за `build`/`@refactor`,
  и до готового дизайна реализацию не начинают.

## Layout (ownership)

- `agent/` — opencode subagents (`issue-writer`, `screenshot-report`,
  `component-builder`, `refactor`, `task-manager`, `task-audit`, `react-fix`, `unit-test`,
  `structurer`, `review`).
  `component-builder` — hidden subagent, read-only проектировщик React-компонентов
  (edit/bash запрещены): выдаёт в чат дерево компонентов, ответственности,
  props-контракты и декомпозицию большого компонента на мелкие, UI-кит
  не навязывает, код не пишет.
  `task-manager` — hidden subagent (вызов только через `/new-task`, `@auto`
  или `task`), думает за весь
  task-manager пайплайн, права зажаты (bash только на `scripts/task-manager/*`).
  `task-audit` — `mode: subagent`, только аудит по делегированию `task-manager`,
  возврат строго JSON по `scripts/task-manager/schema/audit.schema.json`.
  `react-fix` — hidden subagent (вызов только через `/fix`, `@auto`
  или `task`); думает за весь react-fix пайплайн
  (поиск классов — только скриптом, правки — только после выясненного
  «что менять», см. `scripts/react-fix/README.md`).
  `unit-test` — hidden subagent; пишет юнит-тесты под любой фреймворк,
  синтаксис фреймворка — только из Context7 MCP (по памяти запрещено).
  `structurer` — hidden subagent-предобработчик ввода (вызов только через `@auto`/`@plan`,
  `task` → `@structurer`): фаза 1 score 0..6 (`goal/sections/lists/acceptance/context/single_intent` →
  `unstructured 0..2 / partial 3..4 / structured 5..6`), фаза 2 нормализация в md
  (Заголовок + Контекст/Что сделать/Критерии приёмки/Ограничения/Открытые вопросы,
  `[???]` вместо выдумок, N интентов → N блоков); возврат md + JSON
  `{score,level,intents,structured_md,open_questions,needs_confirmation}`; сам `question`
  не задаёт — спрашивает caller.
  `review` — hidden subagent-гейт качества (вызов через `task` → `@review` из
  исполнителей перед `done`, контроль — `@auto` шаг 5b): сверяет diff с `AGENTS.md` +
  `CODE_OF_CONDUCT.md` + `DESIGN.md` (для UI) через `check/run.sh` + `security/design`
  guards по узким критериям Q1..Q8 (задача/контракты/принципы/статика/безопасность/
  тесты/читаемость/гигиена scope); код не правит (`edit: deny`), возвращает
  `{verdict: APPROVED|NEEDS_WORK, findings, for_executor}`; глубина fast/deep —
  внутренней эвристикой, без отдельного classify-tool.
- `skills/tunnel-manager/SKILL.md` — preview-tunnel runner (wraps
  `scripts/tunnel/`).
- `skills/ci/SKILL.md` — vendor-lock-free GitHub Actions CI/CD (требования→исполнение): `@ci` (hidden subagent) опрашивает пользователя (type/registry/image/platforms/cache/deploy + монорепо `apps/<app>`) → `task → @ci-runner` (`hidden:subagent`) скаффолдит `scripts/ci/scaffold.sh --type ci|docker|all [--monorepo --app]` из `scripts/ci/templates/*.yml` → `.github/workflows/`; `workflows.sh status|logs` — read-only; registry-agnostic (`vars.DOCKER_REGISTRY`/`vars.DOCKER_IMAGE`/`secrets.REGISTRY_*` + `GITHUB_TOKEN` fallback), buildx + gha cache, `paths: apps/<app>/**` для монорепо, без cloud-экшенов.
- `skills/init/SKILL.md` — onboarding инициализации `.devbox` (требования→исполнение): `@init` (hidden subagent) опрашивает пользователя (remote, монорепо, микросервисы, frontend/backend/database, тип draft/mvp, коммиты all/batch, комментарии `COMMENTS_DETAILS 0..9`) → `task → @init-runner` (`hidden:subagent`) пишет `.devbox` через `scripts/task-manager/init.sh` с `PROFILE_*` + `COMMENTS_DETAILS` (можно коммитить), без секретов. Миграция legacy — `migrate.sh` первым шагом.
- `skills/docker-pack/SKILL.md` — упаковка Docker по слоям (требования→исполнение): любой агент `task → @docker-pack` (`hidden:subagent`) → `task → @recon` (stack/зависимости) → `scripts/docker-pack/scaffold.sh --stack node|python|go [--app --context --dockerfile]` из `scripts/docker-pack/templates/Dockerfile.*` + `.dockerignore` (deps кэш отдельно от `COPY .`, multi-stage, non-root runner); монорепо `apps/<app>` контекст изолирован.
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
- `scripts/pr/` — `schema/pr.schema.json` (LLM contract) +
  `validate-pr-data.py` → `render-pr.py` → `create-pr.sh` (`gh`/`glab`/`tea`/
  REST bitbucket, контракт: последняя строка stdout всегда `PR_URL: <url>`) +
  `get-pr-url.sh` (read-only поиск PR текущей ветки: `PR_URL:` или
  `PR_URL: none`; вызывается после любых git-операций и при любом
  упоминании PR) + `status-pr.sh` (ЕДИНСТВЕННЫЙ источник правды о статусе:
  конфликты/checks/reviews/lifecycle; агент сверяется с ним перед любым
  ответом про PR, а не гадает; see `scripts/pr/README.md`).
- `scripts/react-fix/` — `find-class.sh` (поиск CSS-класса в tsx/css →
  таблица `FILE|LINE|KIND|TEXT` для ИИ; точное имя + BEM-дети, без
  подстрок; read-only; см. `scripts/react-fix/README.md`).
- `scripts/design/` — `template.md` (скелет `DESIGN.md`: платформы, стек,
  токены, компоненты, конвенции, журнал решений) + `init.sh`
  (создать файл из шаблона если нет; `--check`/`--force`) + `context.sh`
  (программный автоинжект правил в контекст: компактный блок/JSON) +
  `guard.sh` (guardrail перед коммитом: только незакоммиченные UI-изменения
  против `DESIGN.md`; error — стоп + approve человека; см.
  `scripts/design/README.md`). Сам `DESIGN.md` живёт в корне
  consumer-проекта, не в `.opencode/`; читают/обновляют только UI-агенты.
- `scripts/security/` — `guard.sh` (guardrail I/O перед КАЖДЫМ коммитом:
  только незакоммиченные изменения; error `dangerous-sink`, warn
  `sql-concat`/`unvalidated-input`/`unvalidated-form`; error — стоп +
  approve человека; разбор — `@security` через `task`; см.
  `scripts/security/README.md`).
- `scripts/sync/` — `run.sh` (deterministic `git pull --rebase --autostash`
  of current branch; no `merge`/`--force`; see `scripts/sync/README.md`).
- `scripts/task-manager/` — `init.sh` (project tag → `.devbox`) +
  `migrate.sh` (legacy `.devbox-project` / `.trello-project` → `.devbox`, валидация `COMMENTS_DETAILS=0..9`) +
  `boards.sh` / `lists.sh` (discovery) + `create.sh` (card with NAME label)
  + `move.sh` (card → target list via PUT `idList`, `--dry-run` без мутаций)
  + `checklist.sh` (подзадачи чек-листом: create/add-item/complete/show JSON)
  + `comments.sh` (комментарии карточки: `--show` JSON + add/edit/delete)
  + `audit.sh` (read-only board audit → JSON для `task-audit`, парсит
  `Blocked by:` в `blocked_by`) + `schema/audit.schema.json` (AI-контракт),
  всё via Trello REST; агент думает, скрипты исполняют; see
  `scripts/task-manager/README.md`).
- `opencode.json` — `default_agent: build`, only pre-approved bash is
  `bash .opencode/scripts/tunnel/run.sh*` +
  `bash .opencode/scripts/push/run.sh*` +
  `bash .opencode/scripts/sync/run.sh*` +
  `bash .opencode/scripts/pr/*` +
  `bash .opencode/scripts/design/*` +
  `bash .opencode/scripts/ci/*` + `bun workflows/*` +
  `bash .opencode/scripts/react-fix/*` (read-only class search); `mcp.trello` (`npx -y
  @delorenj/mcp-server-trello`, ключи только через `{env:TRELLO_API_KEY}` /
  `{env:TRELLO_TOKEN}`) + `mcp.context7` (remote `https://mcp.context7.com/mcp`,
  ключ опционален через `{env:CONTEXT7_API_KEY}`) + `mcp.dokploy`
  (`npx -y @dokploy/mcp`, `DOKPLOY_URL` + `DOKPLOY_API_KEY` только через
  `{env:...}`, пресет `minimal` против 508 инструментов; секреты
  в репозиторий не коммитить). Root `package.json`
  has only `@opencode-ai/plugin`, no scripts.

## Departments (отделы)

Агенты поделены на отделы по стадиям пайплайна — отдел определяет зону
ответственности. Точка входа — только `@auto` + slash-команды (тонкие
раннеры на builtin `build` с делегированием через `task`); все остальные
кастомные агенты — hidden subagents за workflows/классификатором, напрямую
пользователем не вызываются. Вектор — workflow-модель и программное
управление моделями/агентами.
Владелец `DESIGN.md` — человек; агентам всех отделов файл
только для чтения, правки вносит только владелец по точным предложениям
агентов (патч в чат → вносит человек → approve → коммит). Запрет правок
привязан к UI-ядру (`react-*` + любой агент за UI-задачей), а не к отделу.

| Отдел (стадия) | Агенты | `DESIGN.md` |
| -------------- | ------ | ----------- |
| разведка | `recon`, `ask`, `structurer` | read-only |
| планирование | `plan`, `auto`, `evol-plan` | read-only |
| задачи | `task-manager`, `task-audit`, `task-batch`, `task-explain`, `issue-writer`, `init`, `init-runner` | read-only |
| исполнение | `build-fast`, `build-smart`, `react-architect`, `react-concept`, `react-implement`, `react-fix`, `refactor`, `devops`, `docker-pack`, `ci`, `ci-runner`, `unit-test` | read-only; UI-ядро (`react-*`) — правки строго запрещены |
| проверка | `diagnostics`, `screenshot-report`, `review` | read-only |
| доставка | `commit-writer`, `worktree-manager`, `tunnel-manager` | read-only |
| безопасность (сквозной) | `security` (hidden subagent-аудитор I/O) | читает guard-нарушения, предлагает validator-патчи, код не правит |

## Code comments (`COMMENTS_DETAILS` in `.devbox`)

- `COMMENTS_DETAILS=0..9` — детальность комментариев в коде; хранится в `.devbox`, валидируется скриптами (`init.sh`/`migrate.sh`/`_common.sh`), невалидное = `exit 1`, работа прекращается.
- `0` — не писать комментарии вообще, даже если требуется; этот параметр сильнее любых промптов и `AGENTS.md`.
- `9` — подробные комментарии на каждую строку; `1..8` — линейно между крайностями.
- Отсутствует — поведение по умолчанию агента; спрашивать через `@init` (вопрос 9), писать только через `init.sh --comments-details N`.

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
# pr (создание + гарантированная ссылка; чтение ссылки после любых git-операций):
echo '<json>' | python3 .opencode/scripts/pr/validate-pr-data.py > /tmp/pr.json  # needs pip install jsonschema
python3 .opencode/scripts/pr/render-pr.py github --json /tmp/pr.json  # preview body
bash .opencode/scripts/pr/get-pr-url.sh [--branch <name>]
bash .opencode/scripts/pr/create-pr.sh --title "<title>" --json /tmp/pr.json --base main [--draft] [--dry-run]
# create-pr.sh всегда печатает `PR_URL: <url>` — агент ретранслирует её пользователю.
# get-pr-url.sh печатает `PR_URL: <url>` или `PR_URL: none` — вызывать после /push / /sync / /commit.
# status-pr.sh — сверка перед ЛЮБЫМ ответом про состояние PR; отвечать только по его выводу.
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
bash .opencode/scripts/task-manager/migrate.sh            # legacy .devbox-project/.trello-project → .devbox (первым шагом)
bash .opencode/scripts/task-manager/init.sh [--name <tag>] [--force] [--comments-details <0-9>]   # конфиг → .devbox (NAME + COMMENTS_DETAILS)
bash .opencode/scripts/task-manager/boards.sh                          # мои доски (точные имена)
bash .opencode/scripts/task-manager/lists.sh --board "<name>"          # листы доски
bash .opencode/scripts/task-manager/create.sh --title "<t>" [--board "<b>"] [--list "<l>"] [--desc "<d>"] [--save-defaults]
bash .opencode/scripts/task-manager/move.sh (--id <id> | --url <url> | --card "<name>") --list "<target>" [--to-board "<b>"] [--dry-run]
bash .opencode/scripts/task-manager/checklist.sh --card "<name>" --create "Подзадачи" --items "Шаг 1;Шаг 2"
bash .opencode/scripts/task-manager/comments.sh --id "<shortLink>" --show  # комментарии задачи текстом (JSON)
bash .opencode/scripts/task-manager/audit.sh --board "<name>" [--tag "<t>" | --all]  # JSON для task-audit
# карточка — сразу по просьбе пользователя, без «да»; нужны TRELLO_API_KEY/TRELLO_TOKEN в env.
```

```bash
# react-fix (agent runs this ONLY via /fix or @react-fix; script finds, agent asks, then edits):
bash .opencode/scripts/react-fix/find-class.sh --class journal [--class header] [--root src]
# → таблица FILE|LINE|KIND|TEXT → если неясно что/где править — вопрос пользователю (без edit!) →
# → точечная правка только подтверждённого → проверка командами consumer-проекта.
```

```bash
# design (только UI-агенты; DESIGN.md в корне проекта, не в .opencode/):
bash .opencode/scripts/design/init.sh --check   # есть — exit 0, нет — exit 1
bash .opencode/scripts/design/init.sh           # создать из шаблона если нет (есть — no-op)
bash .opencode/scripts/design/context.sh        # автоинжект правил в контекст задачи
bash .opencode/scripts/design/guard.sh          # guardrail незакоммиченного перед add/commit
# дальше агент заполняет разделы по коду/опросу и работает строго по файлу;
# после UI-задачи — обновить разделы + строка в журнале решений с датой.
# guard error — стоп и явный approve человека, без approve коммита нет.
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
