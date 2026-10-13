# chain — цепочки агентов с кэшем

Философия: LLM-вызовы дороги, файлы дёшевы. Каждая стадия пишет артефакт,
оркестратор (`/chain`) склеивает их в итоговый промпт исполнителя, а
контентный кэш позволяет переиспользовать стадии между ранами и после
откатов — ноль новых токенов за то, что уже посчитано.

```
цель
  │
  ▼
route ──тривиально──▶ build (напрямую)
  │ полная цепочка
  ▼
research (explore-сабагенты, параллельно) → stages/research.md ─┐
  │ ключ: research + hash(goal)                                  │ cache
  ▼                                                              │
plan (сабагент-планировщик) → stages/plan.md ───────────────────┤
  │ ключ: plan + hash(research*, goal)                           │
  ▼                                                              │
assemble → final-prompt.md ──▶ build (сам или сабагент) ──▶ verify
```

## Файлы

- `run.sh` — весь каркас: `init`, `hash`, `cache-get`/`cache-put`,
  `stage-put`, `assemble`, `restore`, `list`, `show`. Только хранение,
  хэши и склейка — никакого LLM, агентов он не запускает.
- `runs/<run-id>/` — рантайм (gitignored): `goal.md`, `meta.json`,
  `stages/*.md`, `final-prompt.md`.
- `cache/<key>/artifact.md` — рантайм (gitignored): ключ = stage + hash
  всех входов стадии.
- `commands/chain.md` — `/chain`, оркестратор: роут → стадии через
  `subagent` → сборка → исполнитель → verify → откат через `restore`.

## Быстрый прогон вручную (без агентов, проверка скрипта)

```bash
RUN=$(bash .opencode/scripts/chain/run.sh init --goal "починить логин" --slug demo)
echo "факты: ..." | bash .opencode/scripts/chain/run.sh stage-put "$RUN" research -
KEY="research-$(bash .opencode/scripts/chain/run.sh hash .opencode/scripts/chain/runs/$RUN/goal.md)"
bash .opencode/scripts/chain/run.sh cache-put "$KEY" .opencode/scripts/chain/runs/$RUN/stages/research.md
bash .opencode/scripts/chain/run.sh cache-get "$KEY"
bash .opencode/scripts/chain/run.sh assemble "$RUN" research
bash .opencode/scripts/chain/run.sh show "$RUN"
bash .opencode/scripts/chain/run.sh restore "$RUN" research
bash .opencode/scripts/chain/run.sh list
```

## Точки адаптации

1. **Стадии**: дефолт `research plan` в `assemble` — поменяй список под свой
   пайплайн (имена `stages/*.md` произвольные, `assemble` берёт префиксы).
2. **Кэш**: инвалидация — только сменой входов (ключ контентный). Ручной сброс:
   удалить `cache/<key>/`. TTL нет осознанно — артефакт либо валиден, либо нет.
3. **Модели**: temperature/модель стадий выбирает оркестратор через сабагентов,
   скрипту всё равно.
