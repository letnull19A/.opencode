#!/usr/bin/env bash
# migrate.sh — миграция проектного конфига в канонический файл `.devbox`.
#
# Каноника: `.devbox` (env-формат, без секретов, можно коммитить).
# Legacy-источники (проверяются по порядку): `.devbox-project`, `.trello-project`.
# Содержимое переносится как есть (NAME/BOARD/LIST/PROFILE_*/COMMENTS_DETAILS);
# скрипт только переименовывает (git mv если файл в индексе, иначе mv)
# и валидирует COMMENTS_DETAILS.
#
# COMMENTS_DETAILS — детальность комментариев в коде, целое 0..9:
#   0 — не писать комментарии вообще (сильнее любых промптов и AGENTS.md,
#       даже если «требуется»);
#   9 — подробные комментарии на каждую строку.
#   1..8 — линейно между крайностями (больше значение — подробнее).
# Невалидное значение = жёсткая ошибка, работа прекращается (exit 1).
#
# Использование (из корня проекта):
#   bash .opencode/scripts/task-manager/migrate.sh [--dry-run] [--force]
#   PROJECT_FILE=.devbox bash .opencode/scripts/task-manager/migrate.sh
#
#   --dry-run  только показать план, ничего не двигать.
#   --force    если каноника и legacy существуют одновременно —
#              перезаписать канонику из legacy (по умолчанию каноника побеждает).

set -euo pipefail

TARGET="${PROJECT_FILE:-.devbox}"
DRY_RUN=0
FORCE=0

usage() {
  echo "Usage: migrate.sh [--dry-run] [--force]"
  echo "  Мигрирует .devbox-project / .trello-project → ${TARGET} (по умолчанию .devbox)."
  echo "  Валидирует COMMENTS_DETAILS=0..9, при ошибке — exit 1."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "migrate: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

die() { echo "migrate: $*" >&2; exit 1; }

# Валидация COMMENTS_DETAILS в файле: пусто/отсутствует — ок,
# иначе ровно одна цифра 0..9, иначе — жёсткая ошибка.
validate_comments_details() { # <file>
  local file="$1" raw val
  raw="$(grep -E '^COMMENTS_DETAILS=' "$file" 2>/dev/null || true)"
  [[ -z "$raw" ]] && return 0
  # при дублях берём последнее значение
  raw="$(printf '%s\n' "$raw" | tail -n 1)"
  val="${raw#COMMENTS_DETAILS=}"
  # снять кавычки '"..."' / '...'
  val="$(printf '%s' "$val" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")"
  # trim пробелов
  val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ "$val" =~ ^[0-9]$ ]] || die "$file: COMMENTS_DETAILS='$val' — нужно целое 0..9 (0 — без комментариев вообще, 9 — на каждую строку). Работа прекращена."
}

move_file() { # <src> <dst>
  local src="$1" dst="$2"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git ls-files --error-unmatch "$src" >/dev/null 2>&1; then
    git mv "$src" "$dst" 2>/dev/null || mv "$src" "$dst"
  else
    mv "$src" "$dst"
  fi
}

SOURCES=()
[[ "$TARGET" != ".devbox-project" ]] && SOURCES+=(".devbox-project")
[[ "$TARGET" != ".trello-project" ]] && SOURCES+=(".trello-project")
# legacy-цепочка для каноники .devbox: сначала .devbox-project, затем .trello-project
if [[ "$TARGET" == ".devbox" ]]; then
  SOURCES=(".devbox-project" ".trello-project")
fi

SRC=""
for cand in "${SOURCES[@]:-}"; do
  if [[ -f "$cand" ]]; then SRC="$cand"; break; fi
done

if [[ -f "$TARGET" ]]; then
  if [[ -n "$SRC" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "(dry-run) перезаписал бы $SRC → $TARGET (--force)"
        validate_comments_details "$SRC"
        echo "(dry-run) COMMENTS_DETAILS в $SRC — ок"
        exit 0
      fi
      cp "$SRC" "$TARGET"
      # stale legacy удаляем через git rm если трекался, иначе rm
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git ls-files --error-unmatch "$SRC" >/dev/null 2>&1; then
        git rm -q "$SRC" 2>/dev/null || rm -f "$SRC"
      else
        rm -f "$SRC"
      fi
      echo "(i) migrated $SRC → $TARGET (--force, перезапись)"
    else
      echo "(i) каноника уже есть ($TARGET), legacy $SRC не тронут. Проверь и удали вручную, либо --force для перезаписи." >&2
    fi
  else
    [[ "$DRY_RUN" -eq 1 ]] && echo "(dry-run) $TARGET уже на месте, делать нечего"
  fi
  validate_comments_details "$TARGET"
  echo "== $TARGET: COMMENTS_DETAILS — ок =="
  if [[ "$DRY_RUN" -eq 0 ]]; then cat "$TARGET"; fi
  exit 0
fi

# каноники нет — ищем источник
[[ -n "$SRC" ]] || die "нет ни $TARGET, ни legacy (${SOURCES[*]:-—}) — сначала: bash .opencode/scripts/task-manager/init.sh"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "(dry-run) переместил бы $SRC → $TARGET"
  validate_comments_details "$SRC"
  echo "(dry-run) COMMENTS_DETAILS в $SRC — ок"
  exit 0
fi

move_file "$SRC" "$TARGET"
echo "(i) migrated $SRC → $TARGET" >&2
validate_comments_details "$TARGET"

echo "== записано ($TARGET) =="
cat "$TARGET"
