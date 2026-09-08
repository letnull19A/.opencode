# issue-writer — агент + пайплайн

Реализация философии: **один агент = одно действие, доведённое до 10/10**;
всё, что можно сделать скриптом без LLM — делается скриптом.

```
[контекст диалога/кода]
        │
        ▼
┌─────────────────────────┐   LLM здесь. Единственное место,
│  @issue-writer (subagent)│   где агент "думает". Выход — ТОЛЬКО
│  → issue JSON            │   JSON по issue.schema.json.
└───────────┬──────────────┘
            ▼
  validate-issue-data.py      ← чистый код, реджект если не по схеме
            │
            ▼
     detect-provider.sh       ← чистый код: AGENTS.md `issue_provider:`
            │                    или автодетект по git remote
            ▼
      render-issue.py         ← чистый код: JSON → markdown
      (шаблон под провайдера)   под конвенции github/gitlab/gitea/bitbucket
            │
            ▼
      create-issue.sh         ← чистый код: вызывает gh / glab / tea /
                                 REST API bitbucket (готовые CLI, не свои)
```

`orchestrate.sh` просто клеит шаги 2–4 в правильном порядке.
Сам он тоже не LLM.

## Файлы

- `.opencode/agent/issue-writer.md` — subagent с урезанными правами
  (`write: false`, `edit: false`, bash разрешён только на конкретные команды).
  Это не только промпт-дисциплина, но и механическое ограничение через
  `permission:` — агент физически не может сделать ничего, кроме сбора
  данных и их валидации.
- `schema/issue.schema.json` — контракт вывода LLM-шага.
- `detect-provider.sh`, `render-issue.py`, `create-issue.sh`,
  `validate-issue-data.py` — детерминированные шаги, ноль LLM.
- `orchestrate.sh` — склейка шагов 2–4.
- `AGENTS.md.snippet` — что добавить в AGENTS.md проекта.

## Точки адаптации под твой opencode

1. **Модель**: намеренно не задана в `issue-writer.md`. Пропиши в своём
   `opencode.json` (`agent.issue-writer.model`) или оставь наследование
   от текущего primary-агента — тебе решать по проекту/бюджету.
2. **Путь к agent-файлам**: у части версий opencode это `.opencode/agent/`,
   у части — `.opencode/agents/` (множественное число). Проверь в доке
   своей версии и при необходимости переименуй папку.
3. **`permission:` в frontmatter** — синтаксис пермишенов у opencode
   менялся между версиями (V1 vs V2 config). Если твой конфиг — V2,
   вынеси правила в `opencode.json` → `permissions: [...]` с
   `resource`-паттернами вместо inline `permission:` в md-файле
   (пример в доках opencode.ai/docs/permissions).
4. **CLI-тулы вместо самописных вызовов API**: `create-issue.sh` уже
   использует официальные `gh`/`glab`/`tea` — их не нужно оборачивать
   своим кодом сверх тонкого CLI-wrapper'а. Bitbucket — единственный
   провайдер без вменяемого CLI, там честный REST через curl.
5. **Шаблоны рендера** (`render-issue.py::render`) — если у вас в
   проекте свои конвенции issue (другие секции, свои labels-маппинги
   на проект), меняется только эта функция, остальной пайплайн не трогаем.

## Быстрый прогон вручную (без opencode, для проверки скриптов)

```bash
echo '{
  "type": "bug",
  "title": "Login button does nothing on Safari",
  "description": "Clicking login on Safari 17 does not trigger the auth flow.",
  "steps_to_reproduce": ["Open app in Safari 17", "Click Login"],
  "expected": "Auth redirect happens",
  "actual": "Nothing happens, no console errors",
  "environment": "Safari 17.4, macOS 14",
  "labels": ["bug", "safari"],
  "priority": "high"
}' | python3 .opencode/scripts/issue-writer/validate-issue-data.py > /tmp/issue.json

bash .opencode/scripts/issue-writer/orchestrate.sh preview /tmp/issue.json
```