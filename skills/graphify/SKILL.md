---
name: graphify
description: Индексация файлов и быстрый поиск по ним и содержимому через .opencode/scripts/graphify/run.sh. Используй вместо glob/grep когда нужен быстрый поиск по имени файла или по коду, особенно если glob падает на /root/.cache (ripgrep temp).
---

Ты — пользователь graphify, не grep напрямую. Все команды — из корня репо, bash только через `scripts/graphify/run.sh` (разрешён в `opencode.json`).

## Почему graphify, а не glob/grep

- `glob`/`grep` (ripgrep) создают temp в `/root/.cache` → `PermissionDenied: FileSystem.makeTempDirectoryScoped` в этом окружении. `graphify` ставит `TMPDIR=/tmp/opencode` и обходит падение.
- Индекс кешируется в `/tmp/opencode/graphify/<hash>/index.json` по `git HEAD` + `git status` — повторный `index` без `--force` мгновенный.
- Вывод — только JSON (AI-first), без markdown — парсишь `file_results`/`content_results`.

## Команды

1. **Индекс (построй/обнови, идемпотентно):**
   `bash .opencode/scripts/graphify/run.sh index [--root <path>] [--force]`
   - `--root` — корень репо (по умолчанию `git rev-parse --show-toplevel` или `pwd`)
   - `--force` — переиндексация даже если `HEAD` не менялся
   - Без `--force` второй вызов вернёт кеш. Первый прогон: `348 файлов` для `milesnear-webapp`.
   - Пример: `bash .opencode/scripts/graphify/run.sh index --root /workspace/milesnear-webapp --json | head`

2. **Поиск (file | content | both):**
   `bash .opencode/scripts/graphify/run.sh search --query <q> [--mode file|content|both] [--limit <n>] [--root <path>] [--json]`
   - `--mode file` — только по имени файла (по индексу, быстро, `*?[]` как glob)
   - `--mode content` — только по содержимому (rg --json → fallback grep -RIn)
   - `--mode both` — оба (по умолчанию, лимит делится пополам)
   - `--limit 0` — без лимита, по умолчанию `50`
   - `--json` — только JSON на stdout (иначе JSON + `summary:` на stderr)
   - Авто-индекс: если индекса нет — создаст тихо сам.

3. **Статус:**
   `bash .opencode/scripts/graphify/run.sh status [--root <path>]`
   - `root, count, indexed_at, hash, path`

## Формат вывода search (stdout — только JSON)

```json
{
  "query": "StatusSection",
  "mode": "both",
  "root": "/workspace/milesnear-webapp",
  "limit": 5,
  "file_results": [{"path": "frontend/src/components/dashboard/status-section.tsx", "score": 2}],
  "content_results": [{"path": "frontend/src/lib/queries.ts", "line": 48, "column": 0, "text": "export function StatusSection...", "score": 1}],
  "totals": {"file_matched": 1, "content_matched": 5, "total": 6},
  "hint": "file_results — по имени файла (индекс), content_results — по содержимому (rg/grep). Для ИИ: file_results[].path — открой read, content_results[].path:line — точное место."
}
```

- `file_results[].path` — относительный от `root`, `score` 3=точное имя, 2=вхождение в basename, 1=вхождение в путь. Нормализует `StatusSection` ↔ `status-section` (убирает `-_`, lower).
- `content_results[].path:line:column` — точное место, `text` — до 500 символов строки.

## Рецепты для агента

```bash
# 1. Найти файл по имени (вместо glob **/*onboarding*)
bash .opencode/scripts/graphify/run.sh search --query "onboarding" --mode file --limit 10 --json

# 2. Найти где используется onboardingCompleted (вместо grep)
bash .opencode/scripts/graphify/run.sh search --query "onboardingCompleted" --mode content --limit 10 --json

# 3. Оба сразу (как в explorator)
bash .opencode/scripts/graphify/run.sh search --query "StatusSection" --mode both --limit 20 --json

# 4. Глоб-паттерн по файлам
bash .opencode/scripts/graphify/run.sh search --query "*.tsx" --mode file --limit 30 --json
bash .opencode/scripts/graphify/run.sh search --query "*onboarding*" --mode file --limit 20 --json
```

## Reuse-first query-шаблоны (поиск до создания нового)

Перед созданием файла/компонента/модуля/хука/типа — прогони минимум 2 шаблона, зафиксируй `reuse:{queries,found,reused|created_new_why}`:

```bash
# A. Сущность по имени файла (conceptual `graphify query "<что>"`)
bash .opencode/scripts/graphify/run.sh search --query "<Name>" --mode file --limit 10 --json

# B. Символ/функция по коду (conceptual `graphify explain "<концепция>"`)
bash .opencode/scripts/graphify/run.sh search --query "<symbolName>" --mode content --limit 10 --json

# C. Связи A↔B (conceptual `graphify path "<A>" "<B>"`): два поиска + read пересечения
bash .opencode/scripts/graphify/run.sh search --query "<A>" --mode both --limit 20 --json
bash .opencode/scripts/graphify/run.sh search --query "<B>" --mode both --limit 20 --json
# открой read 1–2 пересечения (40–60 строк вокруг матча), не копируй файлы целиком
```

- Кандидат есть → переиспользуй (import/extend/compose на минимальном scope), `add` становится `update`.
- Ничего нет → новое допустимо, но укажи `created_new_why` (что искал, почему не подошло).

## Правила

- Всегда `search --json` — парсь JSON, не текст. `file_results` → `read` файл, `content_results` → `read` с `offset` по `line`.
- Не делай `grep -r` / `find` / `glob` напрямую — они падают на `/root/.cache`. Если `graphify` недоступен — поставь `TMPDIR=/tmp/opencode XDG_CACHE_HOME=/tmp/opencode` перед `rg`.
- Индекс уважает `.gitignore` (`git ls-files --cached --others --exclude-standard`), игнорит `node_modules/.next/dist/build/.git/coverage`, бинари >2MB.
- После `git` мутаций (commit/checkout) — индекс авто-инвалидируется по `HEAD+status`, но можешь `index --force` если нужно.
- Мутаций нет — только чтение, `edit: deny` не нужен.
