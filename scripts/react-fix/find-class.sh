#!/usr/bin/env bash
# find-class.sh — ищет упоминания CSS-класса в React-разметке и стилях.
#
# Рутина пайплайна react-fix: агент НЕ ищет классы руками через grep/rg —
# он вызывает этот скрипт и разбирает таблицу. Решение «что править»
# принимают агент и человек, поиск — только скрипт.
#
# Что ищет: точный класс + его BEM-потомки (__el, --mod), как в разметке
# (className="journal", clsx/cn(...), styles.journal), так и в стилях
# (.journal { ... }, .journal__item, .journal:hover).
# Подстроки-совпадения отсекаются: `journal` НЕ сматчит `journalism`.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/react-fix/find-class.sh --class journal
#   bash .opencode/scripts/react-fix/find-class.sh .journal .header
#   bash .opencode/scripts/react-fix/find-class.sh --class journal --root src
#
# Вывод (удобный для ИИ формат) — на каждый класс свой блок:
#   == class: journal ==
#   FILE | LINE | KIND | TEXT
#   src/widgets/Journal.tsx | 42 | markup | <div className="journal ...">
#   src/widgets/journal.module.css | 7 | style | .journal { display: grid; ... }
#   => journal: 2 matches in 2 files
#
# KIND: markup — ts/tsx/js/jsx (разметка), style — css/scss/sass/less.
#
# Коды выхода: 0 — хоть что-то найдено; 1 — ничего не найдено ни по одному
# классу (агент показывает подсказку и спрашивает, а не гадает);
# 2 — ошибка использования.
#
# Зависимости: python3 (как и у остальных скриптов пака) + rg или grep.

set -euo pipefail

CLASSES=()
ROOT="."

usage() {
  echo "Usage: find-class.sh --class <name> [--class <name2> ...] [--root <dir>]"
  echo "       find-class.sh <name> [.name2 ...] [--root <dir>]"
  echo "  Имя класса — с точкой или без (.journal == journal)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class)
      [[ $# -ge 2 ]] || { echo "find-class: --class требует имя класса" >&2; usage >&2; exit 2; }
      CLASSES+=("$2"); shift 2 ;;
    --root)
      [[ $# -ge 2 ]] || { echo "find-class: --root требует директорию" >&2; usage >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "find-class: неизвестный аргумент '$1'" >&2; usage >&2; exit 2 ;;
    *) CLASSES+=("$1"); shift ;;
  esac
done

[[ "${#CLASSES[@]}" -gt 0 ]] || { echo "find-class: укажи класс: --class journal" >&2; usage >&2; exit 2; }
[[ -d "$ROOT" ]] || { echo "find-class: нет директории '$ROOT'" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || { echo "find-class: нужен 'python3' (не найден в PATH)" >&2; exit 2; }
if command -v rg >/dev/null 2>&1; then
  SEARCHER="rg"
elif command -v grep >/dev/null 2>&1; then
  SEARCHER="grep"
else
  echo "find-class: нужен 'rg' или 'grep' (ничего не найдено в PATH)" >&2; exit 2
fi

# Расширения: разметка/код vs стили (React-проект; остальное не смотрим).
CODE_EXT=(tsx jsx ts mts cts js mjs cjs)
STYLE_EXT=(css scss sass less)
EXCLUDE_DIRS=(.git node_modules dist build coverage .next out vendor tmp cache)

# Сырой построчный поиск `файл:строка:текст` для одного класса.
search_raw() { # <class>
  local cls="$1"
  # Точный класс + опциональные BEM-суффиксы, с нетривиальными границами
  # (работает и в rg, и в grep -E: без lookaround'ов, их нет в Rust regex).
  local pat="(^|[^A-Za-z0-9_-])${cls}(__[A-Za-z0-9_-]+)?(--[A-Za-z0-9_-]+)?([^A-Za-z0-9_-]|\$)"
  if [[ "$SEARCHER" == "rg" ]]; then
    local args=(-n --no-heading --color never -e "$pat")
    for e in "${CODE_EXT[@]}" "${STYLE_EXT[@]}"; do args+=(-g "*.${e}"); done
    for d in "${EXCLUDE_DIRS[@]}"; do args+=(-g "!${d}/"); done
    args+=(-- "$ROOT")
    rg "${args[@]}" || true
  else
    local args=(-rnE -e "$pat")
    for e in "${CODE_EXT[@]}" "${STYLE_EXT[@]}"; do args+=("--include=*.${e}"); done
    for d in "${EXCLUDE_DIRS[@]}"; do args+=("--exclude-dir=${d}"); done
    args+=(-- "$ROOT")
    grep "${args[@]}" || true
  fi
}

FOUND=0

for raw in "${CLASSES[@]}"; do
  # Точку из `.journal` снимаем, остальное валидируем как имя CSS-класса.
  cls="${raw#.}"
  if ! [[ "$cls" =~ ^[A-Za-z_-][A-Za-z0-9_-]*$ ]]; then
    echo "find-class: плохое имя класса '$raw' (жду .journal или journal)" >&2
    exit 2
  fi

  echo "== class: ${cls} =="
  if search_raw "$cls" | python3 -c '
import sys

cls = sys.argv[1]
CODE = {"tsx", "jsx", "ts", "mts", "cts", "js", "mjs", "cjs"}
MAXLEN = 160

rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    try:
        fname, lineno, text = line.split(":", 2)
    except ValueError:
        continue
    if not lineno.isdigit():
        continue
    ext = fname.rsplit(".", 1)[-1].lower() if "." in fname else ""
    kind = "markup" if ext in CODE else "style"
    snippet = " ".join(text.split())
    if len(snippet) > MAXLEN:
        snippet = snippet[:MAXLEN] + "\u2026"
    rows.append((fname, int(lineno), kind, snippet))

if not rows:
    print(f"=> {cls}: 0 matches")
    print("подсказка: проверь написание класса, BEM-суффикс (__el/--mod),")
    print("другой корень поиска (--root src) или что класс не генерируется кодом.")
    sys.exit(1)

print("FILE | LINE | KIND | TEXT")
for fname, lineno, kind, snippet in sorted(rows):
    print(f"{fname} | {lineno} | {kind} | {snippet}")
files = len({r[0] for r in rows})
print(f"=> {cls}: {len(rows)} matches in {files} files")
' "$cls"; then
    FOUND=1
  fi
done

[[ "$FOUND" -eq 1 ]] || exit 1
