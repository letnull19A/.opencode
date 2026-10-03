#!/usr/bin/env bash
# init.sh — инициализация DESIGN.md в корне consumer-репозитория.
# Создаёт DESIGN.md из template.md, если файла нет. Не затирает без --force.
# Сам файл НЕ правит смысловые разделы — их заполняет агент по коду/опросу.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/design/init.sh [--check] [--force]
#
#   без флагов  создать DESIGN.md если его нет (есть — no-op, exit 0)
#   --check     только проверить: есть — exit 0, нет — exit 1 + подсказка
#   --force     перезаписать DESIGN.md из шаблона (осторожно: сносит правки)
#
# Коды выхода: 0 — есть/создан; 1 — нет (--check) или ошибка.

set -euo pipefail

FORCE=0
CHECK=0

usage() {
  echo "Usage: init.sh [--check] [--force]"
  echo "  Создаёт DESIGN.md из template.md в корне репозитория (не затирает без --force)."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "design/init: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$DIR/template.md"
[[ -f "$TEMPLATE" ]] || { echo "design/init: нет шаблона: $TEMPLATE" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DESIGN="$ROOT/DESIGN.md"

if [[ "$CHECK" -eq 1 ]]; then
  if [[ -f "$DESIGN" ]]; then
    echo "DESIGN.md: exists ($DESIGN)"
    exit 0
  else
    echo "DESIGN.md: missing — создай: bash .opencode/scripts/design/init.sh" >&2
    exit 1
  fi
fi

if [[ -f "$DESIGN" && "$FORCE" -eq 0 ]]; then
  echo "DESIGN.md: already exists ($DESIGN) — не трогаю (для перезаписи: --force)"
  exit 0
fi

if [[ -f "$DESIGN" ]]; then
  echo "DESIGN.md: перезаписываю из шаблона (--force): $DESIGN" >&2
fi
cp "$TEMPLATE" "$DESIGN"
echo "DESIGN.md: created ($DESIGN)"
echo "Дальше агент заполняет разделы по коду/опросу: платформы, стек, токены, компоненты."
