#!/usr/bin/env bash
# doctor — лечение рабочего пространства. Для ВСЕХ агентов без исключения:
# права на запуск (`bash .opencode/scripts/doctor/*: allow`) зашиты в глобальный
# конфиг и в каждый агентский bash-блок. Read-only по умолчанию.
#
#   run.sh check [--json]             # найти проблемы, ничего не меняя
#   run.sh fix --yes [--dry-run]      # prune фантомных worktree + init сабмодулей
#   run.sh fix --yes --replace OLD NEW [--include 'glob'] [--dry-run]
#
# Проверки:
#   worktree-stale     записи git worktree, чьих каталогов нет на диске
#   submodule-missing  неинициализированные сабмодули (main + живые worktree)
#   stale-refs         абсолютные пути в трекинговых текстовых файлах, которых нет
#
# Границы: не трогает .env*/секреты/untracked/remote, никогда не коммитит.
# Замена путей — только явной парой --replace по трекинговым файлам.
# Exit: check → 0 чисто, 1 есть проблемы, 2 usage/git-ошибка;
#       fix → 0 ок, 1 частичный провал, 2 usage.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

MODE="${1:-}"; [[ -z "$MODE" ]] && usage 1; shift
JSON=0; YES=0; DRY=0; REPLACE_OLD=""; REPLACE_NEW=""; INCLUDE=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift;;
    --yes) YES=1; shift;;
    --dry-run) DRY=1; shift;;
    --replace) REPLACE_OLD="${2:?}"; REPLACE_NEW="${3:?}"; shift 3;;
    --include) INCLUDE+=("${2:?}"); shift 2;;
    -h|--help) usage 0;;
    *) echo "doctor: неизвестный аргумент '$1'" >&2; usage 2;;
  esac
done

[[ "$MODE" == check || "$MODE" == fix ]] || { echo "doctor: режим '$MODE' (check|fix)" >&2; exit 2; }
if [[ "$MODE" == fix && "$YES" -ne 1 && "$DRY" -ne 1 ]]; then
  echo "doctor: fix требует явный --yes (мутации только по требованию; --dry-run можно без --yes)" >&2; exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || { echo '{"passed":false,"error":"not_git_repo","issues":[]}'; exit 2; }
cd "$ROOT"

ISSUES_TMP="$(mktemp)"; trap 'rm -f "$ISSUES_TMP"' EXIT
issue() { printf '{"check":"%s","severity":"%s","file":"%s","line":%s,"message":"%s"}\n' "$@" >> "$ISSUES_TMP"; }

# --- 1. worktree-stale -------------------------------------------------------
LIVE_WT=()
cur_wt=""; cur_branch=""
while IFS= read -r line; do
  case "$line" in
    worktree\ *) cur_wt="${line#worktree }" ;;
    branch\ *) cur_branch="${line#branch }" ;;
    detached*) cur_branch="(detached)" ;;
    "") 
      if [[ -n "$cur_wt" ]]; then
        if [[ -d "$cur_wt" ]]; then
          LIVE_WT+=("$cur_wt")
        else
          issue "worktree-stale" "error" "$cur_wt" 0 "каталога нет (ветка $cur_branch) — фантомная запись"
        fi
        cur_wt=""; cur_branch=""
      fi ;;
  esac
done < <(git worktree list --porcelain; echo)
[[ ${#LIVE_WT[@]} -gt 0 ]] || LIVE_WT=("$ROOT")

# --- 2. submodule-missing ----------------------------------------------------
for wt in "${LIVE_WT[@]}"; do
  while IFS= read -r sline; do
    [[ "$sline" == -* ]] || continue
    spath="$(echo "$sline" | awk '{print $2}')"
    issue "submodule-missing" "error" "$wt/$spath" 0 "сабмодуль не инициализирован — конфиг/права из него не грузятся"
  done < <(git -C "$wt" submodule status 2>/dev/null || true)
done

# --- 3. stale-refs -----------------------------------------------------------
MATCHES="$(git grep -n -I -E -e '/(media|mnt|home|root|Users|opt|srv|data|Volumes)/[A-Za-z0-9_@.~+/%-]+' -- . \
  ':!package-lock.json' ':!pnpm-lock.yaml' ':!yarn.lock' ':!Cargo.lock' ':!poetry.lock' ':!Gemfile.lock' ':!*.min.js' 2>/dev/null | head -100 || true)"
if [[ -n "$MATCHES" ]]; then
  while IFS= read -r mline; do
    f="${mline%%:*}"; rest="${mline#*:}"; lno="${rest%%:*}"
    while IFS= read -r cand; do
      cand="${cand%.}"  # точка конца предложения — не часть пути
      [[ -e "$cand" ]] || issue "stale-refs" "warn" "$f" "$lno" "путь $cand отсутствует на диске"
    done < <(echo "$mline" | grep -o -E '/(media|mnt|home|root|Users|opt|srv|data|Volumes)/[A-Za-z0-9_@.~+/%-]+' | sort -u || true)
  done <<< "$MATCHES"
fi

emit_report() {
  local passed="true"
  [[ -s "$ISSUES_TMP" ]] && passed="false"
  {
    echo "{"
    echo "  \"passed\": $passed,"
    echo "  \"issues\": ["
    local first=1
    while IFS= read -r j; do
      [[ "$first" -eq 1 ]] && first=0 || echo ","
      echo -n "    $j"
    done < "$ISSUES_TMP"
    echo ""
    echo "  ]"
    echo "}"
  }
}

if [[ "$MODE" == check ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    emit_report
  else
    if [[ ! -s "$ISSUES_TMP" ]]; then
      echo "doctor: чисто — фантомов, пустых сабмодулей и мёртвых путей нет"
    else
      echo "doctor: найдены проблемы:"
      python3 - "$ISSUES_TMP" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding='utf-8'):
    line = line.strip()
    if not line:
        continue
    d = json.loads(line)
    loc = d['file'] + (':' + str(d['line']) if d['line'] else '')
    print('  [%s] %s: %s — %s' % (d['severity'], d['check'], loc, d['message']))
PY
    fi
  fi
  [[ -s "$ISSUES_TMP" ]] && exit 1 || exit 0
fi

# --- fix ---------------------------------------------------------------------
FAIL=0
say() { [[ "$JSON" -eq 1 ]] || echo "doctor: $*"; }

if grep -q '"check":"worktree-stale"' "$ISSUES_TMP"; then
  if [[ "$DRY" -eq 1 ]]; then
    say "dry-run: git worktree prune (фантомные записи)"
  else
    git worktree prune && say "prune: фантомные worktree убраны" || { say "prune: ОШИБКА"; FAIL=1; }
  fi
fi

if grep -q '"check":"submodule-missing"' "$ISSUES_TMP"; then
  for wt in "${LIVE_WT[@]}"; do
    if git -C "$wt" submodule status 2>/dev/null | grep -q '^-'; then
      if [[ "$DRY" -eq 1 ]]; then
        say "dry-run: git submodule update --init (в $wt)"
      else
        git -C "$wt" submodule update --init 2>&1 | tail -2 || { say "submodule init в $wt: ОШИБКА"; FAIL=1; }
        say "submodule init: $wt"
      fi
    fi
  done
fi

if [[ -n "$REPLACE_OLD" ]]; then
  paths_args=(-- .)
  [[ ${#INCLUDE[@]} -gt 0 ]] && paths_args=("--" "${INCLUDE[@]}")
  mapfile -t targets < <(git grep -l -F -I -e "$REPLACE_OLD" "${paths_args[@]}" 2>/dev/null | grep -v -E '\.env($|\.)|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|\.min\.js$' || true)
  if [[ ${#targets[@]} -eq 0 ]]; then
    say "replace: '$REPLACE_OLD' нигде не найден — нечего менять"
  elif [[ "$DRY" -eq 1 ]]; then
    say "dry-run: замена '$REPLACE_OLD' -> '$REPLACE_NEW' в ${#targets[@]} файлах:"
    printf '  %s\n' "${targets[@]}"
  else
    for t in "${targets[@]}"; do
      python3 - "$t" "$REPLACE_OLD" "$REPLACE_NEW" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY
    done
    say "replace: готово:"; git diff --stat | tail -3
  fi
fi

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
