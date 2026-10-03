#!/usr/bin/env bash
# context.sh — программный автоинжект правил дизайна в контекст агента.
# Читает DESIGN.md из корня репозитория и печатает компактный готовый блок:
# стек одной строкой, токены/компоненты/конвенции как есть, из журнала —
# последние 5 решений, пустые placeholder-строки (`<!-- ... -->`) выкинуты.
# UI-агент выполняет его в начале задачи и дальше работает по этому контексту.
# Никакого LLM — чистая сборка, правила не пересказываются, а цитируются.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/design/context.sh [--json]
#
#   без флагов  markdown-блок на stdout (вставляй в контекст как есть)
#   --json      JSON {source, updated, stack, tokens, components, conventions,
#               decisions, questions} — для машинного разбора
#
# Коды выхода: 0 — контекст выдан; 2 — нет DESIGN.md (сначала init.sh).

set -euo pipefail

JSON=0

usage() {
  echo "Usage: context.sh [--json]"
  echo "  Печатает компактный контекст дизайна из DESIGN.md для инжекта в задачу."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "design/context: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DESIGN="$ROOT/DESIGN.md"

if [[ ! -f "$DESIGN" ]]; then
  echo "design/context: нет DESIGN.md — сначала: bash .opencode/scripts/design/init.sh" >&2
  exit 2
fi

# Убираем пустые placeholder-строки (только HTML-комментарий, без содержимого),
# чтобы в контекст не попадал мусор незаполненного шаблона.
CLEANED="$(grep -vE '^\s*(<!--.*-->\s*)?$' "$DESIGN" | grep -vE '^<!--.*-->$' || true)"

UPDATED="$(grep -oE '[Пп]оследнее обновление:[^<]*' "$DESIGN" | head -n1 | sed -E 's/.*:\s*//' | xargs || true)"
[[ -z "$UPDATED" ]] && UPDATED="unknown"

if [[ "$JSON" -eq 1 ]]; then
  python3 - "$DESIGN" "$UPDATED" << 'PY'
import json, sys, re
path, updated = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
lines = [l for l in text.splitlines() if l.strip() and not re.match(r'^\s*<!--.*-->\s*$', l)]

def section(num):
    out, on = [], False
    for l in lines:
        if re.match(r'^##\s+' + num + r'\.', l):
            on = True
            continue
        if on and re.match(r'^##\s+\d+\.', l):
            break
        if on:
            out.append(l)
    return "\n".join(out).strip()

def tail_list(num, n=5):
    rows = [l for l in section(num).splitlines() if l.startswith('|')]
    rows = [r for r in rows if not re.match(r'^\|\s*-+', r) and 'Дата' not in r]
    return rows[-n:]

print(json.dumps({
    "source": path,
    "updated": updated,
    "stack": section("1"),
    "tokens": section("2"),
    "components": section("3"),
    "layout": section("4"),
    "conventions": section("5"),
    "recent_decisions": tail_list("6"),
    "open_questions": section("7"),
}, ensure_ascii=False, indent=2))
PY
  exit 0
fi

# Markdown-режим: всё как есть, но журнал решений — только последние 5 строк.
{
  echo "## Design context (auto-injected)"
  echo "source: \`$DESIGN\` · updated: $UPDATED"
  echo ""
  echo "$CLEANED" | python3 -c '
import sys, re
lines = sys.stdin.read().splitlines()
out, in_journal = [], False
jhead, jrows = [], []
def flush_journal():
    if jrows:
        out.append("(журнал: последние %d из %d)" % (min(5, len(jrows)), len(jrows)))
        out.extend(jhead)
        out.extend(jrows[-5:])
    elif jhead:
        out.extend(jhead)
for l in lines:
    if re.match(r"^##\s+6\.", l):
        in_journal = True
        out.append(l)
        continue
    if in_journal and re.match(r"^##\s+", l):
        flush_journal()
        in_journal = False
    if in_journal and l.startswith("|"):
        if re.match(r"^\|\s*-+", l) or "Дата" in l:
            jhead.append(l)
        else:
            jrows.append(l)
        continue
    out.append(l)
if in_journal:
    flush_journal()
print("\n".join(out))
'
}
