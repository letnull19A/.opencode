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

## Layout (ownership)

- `agent/` — opencode subagents (`issue-writer`, `screenshot-report`,
  `component-builder`, `refactor`). `component-builder` targets the external
  `@web2bizz/ui` kit, not this repo — don't apply its rules here.
- `skills/tunnel-manager/SKILL.md` — preview-tunnel runner (wraps
  `scripts/tunnel/`).
- `scripts/issue-writer/` — `schema/issue.schema.json` (LLM contract) +
  `validate-issue-data.py` → `detect-provider.sh` → `render-issue.py` →
  `create-issue.sh`, glued by `orchestrate.sh`.
- `scripts/screenshot-report/` — `run.sh` → `capture.js` → `report.js` →
  `send.js`; viewports fixed in `config/viewports.js`; per-script `package.json`.
- `scripts/tunnel/` — `run.sh` → `tunnel.js` (localtunnel/loca.lt),
  per-script `package.json`. State in `~/.local/state/opencode-tunnel/<name>.json`.
- `opencode.json` — `default_agent: build`, only pre-approved bash is
  `bash .opencode/scripts/tunnel/run.sh*`. Root `package.json` has only
  `@opencode-ai/plugin`, no scripts.

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
