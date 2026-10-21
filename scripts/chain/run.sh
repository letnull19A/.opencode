#!/usr/bin/env bash
# Каркас цепочек агентов (research → plan → build).
#
# LLM-агентов запускает НЕ этот скрипт, а оркестратор (команда /chain)
# через subagent. Скрипт лишь ведёт run-директории, считает хэши,
# хранит контентный кэш и склеивает артефакты стадий в итоговый промпт.
#
#   run.sh init --goal "..." [--slug text]  # новый run, печатает run-id
#   run.sh hash <file>...                   # sha256 входов (часть ключа кэша)
#   run.sh cache-get <key>                  # артефакт в stdout; exit 3 = miss
#   run.sh cache-put <key> <file>           # сохранить успешный артефакт
#   run.sh stage-put <run> <stage> <file|-> # сохранить артефакт стадии
#   run.sh assemble <run> [stage...]        # склейка в final-prompt.md (+ stdout)
#   run.sh restore <run> [stage]            # новый run с копиями артефактов (откат)
#   run.sh list                             # все раны
#   run.sh show <run>                       # цель + стадии
#
# Ключ кэша = stage + hash ВСЕХ входов стадии. Кэш валиден, только пока
# совпадают входы. Переиспользование после отката — через restore: новый run,
# старые артефакты, ноль новых токенов за переиспользованные стадии.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS="$DIR/runs"
CACHE="$DIR/cache"

usage() { grep '^#[^!]' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage 0; fi
CMD="${1:-}"; [[ -z "$CMD" ]] && usage 1; shift

case "$CMD" in
  init)
    GOAL=""; SLUG="task"
    while [[ $# -gt 0 ]]; do case "$1" in
      --goal) GOAL="${2:?}"; shift 2;;
      --slug) SLUG="$(echo "${2:?}" | tr -cd 'a-zA-Z0-9-' | head -c 24)"; shift 2;;
      *) echo "init: неизвестный флаг $1" >&2; exit 1;;
    esac; done
    [[ -n "$GOAL" ]] || { echo "init: нужен --goal" >&2; exit 1; }
    RUN="$(date +%Y%m%d-%H%M%S)-$SLUG"
    mkdir -p "$RUNS/$RUN/stages"
    printf '%s\n' "$GOAL" > "$RUNS/$RUN/goal.md"
    printf '{"run":"%s","created":"%s"}\n' "$RUN" "$(date -u +%FT%TZ)" > "$RUNS/$RUN/meta.json"
    echo "$RUN"
    ;;
  hash)
    [[ $# -gt 0 ]] || { echo "hash: нужны файлы" >&2; exit 1; }
    cat "$@" | sha256sum | cut -d' ' -f1
    ;;
  cache-get)
    KEY="${1:?usage: run.sh cache-get <key>}"
    F="$CACHE/$KEY/artifact.md"
    [[ -f "$F" ]] || exit 3
    cat "$F"
    ;;
  cache-put)
    KEY="${1:?usage: run.sh cache-put <key> <file>}"
    SRC="${2:?usage: run.sh cache-put <key> <file>}"
    [[ -f "$SRC" ]] || { echo "cache-put: нет файла $SRC" >&2; exit 1; }
    mkdir -p "$CACHE/$KEY"
    cp "$SRC" "$CACHE/$KEY/artifact.md"
    ;;
  stage-put)
    RUN="${1:?usage: run.sh stage-put <run> <stage> <file|->}"
    STAGE="${2:?usage: run.sh stage-put <run> <stage> <file|->}"
    SRC="${3:?usage: run.sh stage-put <run> <stage> <file|->}"
    D="$RUNS/$RUN/stages"; [[ -d "$D" ]] || { echo "stage-put: нет рана $RUN" >&2; exit 1; }
    if [[ "$SRC" == "-" ]]; then cat > "$D/$STAGE.md"; else cp "$SRC" "$D/$STAGE.md"; fi
    ;;
  assemble)
    RUN="${1:?usage: run.sh assemble <run> [stage...]}"; shift
    D="$RUNS/$RUN/stages"; [[ -d "$D" ]] || { echo "assemble: нет рана $RUN" >&2; exit 1; }
    STAGES=("$@"); [[ ${#STAGES[@]} -eq 0 ]] && STAGES=(research plan)
    OUT="$RUNS/$RUN/final-prompt.md"
    {
      echo "# Контекст цепочки $RUN"; echo
      echo "## Цель"; echo; cat "$RUNS/$RUN/goal.md"; echo
      for s in "${STAGES[@]}"; do
        for f in "$D"/$s*.md; do
          [[ -f "$f" ]] || { echo "assemble: нет артефакта $s" >&2; exit 1; }
          echo "## Стадия: $(basename "$f" .md)"; echo; cat "$f"; echo
        done
      done
    } > "$OUT"
    cat "$OUT"
    ;;
  restore)
    SRC_RUN="${1:?usage: run.sh restore <run> [stage]}"
    ONLY="${2:-}"
    [[ -d "$RUNS/$SRC_RUN" ]] || { echo "restore: нет рана $SRC_RUN" >&2; exit 1; }
    NEW_RUN="$("$0" init --goal "$(cat "$RUNS/$SRC_RUN/goal.md")" --slug restore)"
    if [[ -n "$ONLY" ]]; then
      cp "$RUNS/$SRC_RUN/stages/$ONLY".md "$RUNS/$NEW_RUN/stages/" 2>/dev/null \
        || { echo "restore: нет стадии $ONLY" >&2; exit 1; }
    else
      cp "$RUNS/$SRC_RUN/stages/"*.md "$RUNS/$NEW_RUN/stages/" 2>/dev/null || true
    fi
    echo "$NEW_RUN"
    ;;
  list)
    ls -1 "$RUNS" 2>/dev/null || echo "(пусто)"
    ;;
  show)
    RUN="${1:?usage: run.sh show <run>}"
    [[ -d "$RUNS/$RUN" ]] || { echo "show: нет рана $RUN" >&2; exit 1; }
    echo "== goal =="; cat "$RUNS/$RUN/goal.md"
    echo "== stages =="; ls -1 "$RUNS/$RUN/stages" 2>/dev/null || echo "(нет)"
    [[ -f "$RUNS/$RUN/final-prompt.md" ]] && echo "== final-prompt: yes =="
    ;;
  *) usage 1;;
esac
