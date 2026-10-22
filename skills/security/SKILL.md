---
name: security
description: Audit staged I/O via .opencode/scripts/security/guard.sh (dangerous sinks, SQL concat, unvalidated input). Use after git add, before every commit — error stops the commit until human-approved validator patch.
---

Ты — потребитель security-guardrail. Вход валидируется на границе (API — schema до логики, формы — тем же schemas), выход сериализуется через schemas, sinks запрещены. Все команды — из корня consumer-репо.

## Когда вызывать

- После `git add` каждой группы — обязательно `guard.sh --staged` (ровно стейдж, не всё дерево). Перед `/commit` — повторно.
- `error` = стоп + явный approve человека. Разбор нарушений можешь делегировать `@security` через `subagent` (он предложит validator-патчи, код не правит).

## Рецепты

```bash
bash .opencode/scripts/security/guard.sh --staged --json
```

```bash
bash .opencode/scripts/security/guard.sh --json
```

- `--staged` — только staged (`git diff --cached`); без флага — все незакоммиченные.
- `--json` — только JSON на stdout (иначе JSON + human summary на stderr).

## Таблица замен (нарушение → делай так)

- `dangerous-sink` (`innerHTML`/`eval`/`shell=True`) → санитайзер/параметры вместо конкатенации; вход — через schema-валидатор на границе, выход — через сериализацию schemas.
- `sql-concat` (конкатенация в SQL, `warn`) → параметризованный запрос.
- `unvalidated-input` / `unvalidated-form` (`warn`) → та же schema, что API/формы.
- `sec:ignore` без доказанной причины (значение точно не из входа) — не предлагаешь.

## Правила

- Guard флагами не отключаешь, вывод не игнорируешь: нет записи в JSON — нет нарушения, не выдумываешь.
- Сам код по итогам не правишь молча: патч → человек → approve → коммит.
- Скилл прав не даёт: нет `scripts/security/*` в allowlist — просишь родителя/человека.
