# .opencode — Portable Opencode Pack

This repository is the portable `.opencode` configuration pack that is cloned as `.opencode/` into consumer projects. It provides a deterministic agent, skill, and workflow runtime for [opencode](https://opencode.ai) that standardizes planning, task management, and delivery. Agents think while scripts execute, ensuring all Trello, git, and infra operations remain reproducible and guardrailed. The pack enforces atomic Conventional Commits with Trello trailers and a unix-style one-script-one-task philosophy. It ships with minimal TypeScript workflows that turn a raw phrase like “new task” into a `Taken`-ready card.

## Capabilities

- **Plan Orchestrator** — Improved built-in `Plan` that classifies approach via `classify_plan` (new-module/update/decompose, Jev→heuristic) and delegates to hidden subagents for deterministic planning instead of guessing.
- **Recon Agent** — Two-front reconnaissance that scans local docs (`.docs/docs/specs`) then web (websearch/tavily/context7) and code (tree/grep/graphify-mcp) with token-aware incremental search and a 6-read budget to avoid context overflow.
- **Workflow Engine** — Generic `workflows/engine.ts` runner with guardrails (allowlist, read/write/card budgets, BOARD-lock, dry-run preview gate) and declarative `workflow.json` definitions executed via `tools/workflow.ts`.
- **New-Task Workflow (0→1)** — Five-step pipeline (validate→classify→recon→plan→create) that validates template completeness, builds a Trello card, and supports dry-run preview without mutations.
- **React Two-Stage Pipeline** — Concept stage outputs abstract XML showing nesting/structure, implementation stage maps it to concrete components/tags/props/files for traceable UI design.
- **Task Manager** — Trello CRUD via `scripts/task-manager/*` and `tools/task_*` with project tag from `.devbox-project` (board `Aleksei — Work Hub`), checklist and label helpers, and audit/dump utilities.
- **Git Auditing** — `git-changes` and `task-commits` scripts that join commits to Trello cards via `Trello:` trailers for 1:1 traceability and enforce atomic commits.
- **Router & Tunnel** — Hidden `router`/`build-fast`/`build-smart` and `tunnel-manager` that classify builds and spin preview tunnels when requested, without exposing internals.
- **Skills & Commands** — `/push`, `/sync`, `/commit`, `/new-task`, and `commit`/`task-manager` skills that wrap scripts deterministically and prevent force pushes or manual git mutations.
