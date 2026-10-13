---
description: Run the research → plan → build agent chain with cached file-based context handoffs (init, route, research, plan, assemble, build, verify)
---

You orchestrate an agent chain. LLM-вызовы — дорогая часть: артефакты стадий лежат в `.opencode/scripts/chain/runs/<run>/`, кэш — в `.opencode/scripts/chain/cache/`. Переиспользуй их вместо повторных вызовов. Сабагентов запускаешь только ты через `subagent` — скрипт `run.sh` лишь хранит, хэширует и склеивает.

0. Init: `bash .opencode/scripts/chain/run.sh init --goal "<цель из сообщения>" [--slug <слаг>]` → RUN.
1. Route: тривиальная задача (опечатка, правка в одном файле)? Пропусти шаги 2–4: собери контекст сам и иди к шагу 5. Иначе — полная цепочка.
2. Research: `KEY=research-$(bash .opencode/scripts/chain/run.sh hash runs/<RUN>/goal.md)` (пути — от корня consumer-проекта, но скрипт лежит в `.opencode/scripts/chain/`, хэшируй его `runs/`). Сначала `cache-get $KEY`: hit → `stage-put <RUN> research` через stdin и дальше; miss → запусти 1–3 read-only сабагентов (explore/general) параллельно, их ответы склей в один текст → `stage-put` + `cache-put $KEY` (через tmp-файл).
3. Plan: `KEY=plan-$(hash stages/research*.md goal.md)`. Hit → stage-put; miss → сабагент-планировщик возвращает plan.md → stage-put + cache-put. Ключ = stage + hash ВСЕХ входов; cache-put — только успешный артефакт.
4. Assemble: `bash .opencode/scripts/chain/run.sh assemble <RUN> [stages...]` → `final-prompt.md`. Прочитай его — это контекст исполнителя.
5. Build: маленькая задача — выполни сам по final-prompt; большая/рискованная — делегируй build/refactor-сабагенту, первым сообщением отдав final-prompt целиком.
6. Verify: командами проекта (lint/typecheck/test из AGENTS.md). Упало → чини в том же run. Пользователь сказал «откати» → `run.sh restore <RUN> [stage]` и продолжай в новом run: переиспользованные стадии стоят ноль токенов.
