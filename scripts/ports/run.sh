#!/usr/bin/env bash
# Порты: кто слушает (для devops-агента — вместо прямого `ss`).
# Принимает порты через запятую, отдаёт pid/процесс/адрес в виде,
# который агент сразу разбирает. Только чтение, ничего не меняет.
#
#   bash .opencode/scripts/ports/run.sh 3000-3005,80 [--json]
#   bash .opencode/scripts/ports/run.sh [--json]   # без аргумента = все слушающие
#
# Колонки: порт, протокол, pid, имя процесса (ss, ядро режет до 15 символов),
# полный путь к исполняемому файлу (exe — через /proc/<pid>/exe), адрес.
#
# Выход 0 — всегда (пустой результат = «порты свободны», а не ошибка).
# Выход 1 — неверные аргументы, 2 — нет `ss` (нужен iproute2).
# Чужие процессы без прав видны без pid/имени (там будет `-`).

set -euo pipefail

SPEC=""
JSON=0

usage() {
  echo "Usage: run.sh [3000-3005,80] [--json]"
  echo "  Показывает слушающие сокеты: порт, протокол, pid, процесс, адрес."
  echo "  Без аргумента — все слушающие."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift;;
    -h|--help) usage; exit 0;;
    -*) echo "ports: неизвестный флаг '$1'" >&2; usage >&2; exit 1;;
    *)
      [[ -n "$SPEC" ]] && { echo "ports: спецификация портов уже задана" >&2; exit 1; }
      SPEC="$(echo "$1" | tr -d ' ')"; shift;;
  esac
done

command -v ss >/dev/null 2>&1 || {
  echo "ports: нет команды ss — нужен iproute2 (apt install iproute2)" >&2
  exit 2
}

WANT=""
if [[ -n "$SPEC" ]]; then
  # "3000-3005,80" -> "3000 3001 ... 3005 80" для точного сравнения в awk
  for tok in ${SPEC//,/ }; do
    if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
      (( a >= 1 && b <= 65535 && a <= b )) || { echo "ports: неверный диапазон '$tok'" >&2; exit 1; }
      for ((p = a; p <= b; p++)); do WANT="$WANT $p"; done
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      (( tok >= 1 && tok <= 65535 )) || { echo "ports: неверный порт '$tok'" >&2; exit 1; }
      WANT="$WANT $tok"
    else
      echo "ports: неверный токен '$tok' (нужно N или A-B через запятую)" >&2; exit 1
    fi
  done
fi

ROWS="$(ss -tulpn 2>/dev/null | awk -v want="$WANT" '
  BEGIN { n = split(want, a, /[[:space:]]+/); for (i = 1; i <= n; i++) if (a[i] != "") W[a[i]] = 1 }
  NR == 1 { next }
  {
    proto = $1; state = $2
    m = split($5, ap, ":"); port = ap[m]
    if (want != "" && !(port in W)) next
    rest = substr($0, index($0, $6))
    found = 0
    tmp = rest
    while (match(tmp, /\(\("[^"]+",pid=[0-9]+/)) {
      hit = substr(tmp, RSTART, RLENGTH)
      name = hit; sub(/^\(\("/, "", name); sub(/",pid=.*$/, "", name)
      pid = hit; sub(/^.*pid=/, "", pid)
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", port, proto, state, pid, name, $5
      found = 1
      tmp = substr(tmp, RSTART + RLENGTH)
    }
    if (!found) printf "%s\t%s\t%s\t%s\t%s\t%s\n", port, proto, state, "-", "-", $5
  }' | sort -u -t "$(printf '\t')" -k1,1n -k2,2 || true)"

if [[ -z "$ROWS" ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    echo "[]"
  else
    echo "no listeners"
  fi
  exit 0
fi

if [[ "$JSON" -eq 1 ]]; then
  {
    echo "["
    first=1
    while IFS=$'\t' read -r port proto state pid process addr; do
      exe="-"
      if [[ "$pid" =~ ^[0-9]+$ ]]; then
        exe="$(readlink "/proc/$pid/exe" 2>/dev/null || echo "-")"
      fi
      process="${process//\\/\\\\}"
      process="${process//\"/\\\"}"
      addr="${addr//\\/\\\\}"
      addr="${addr//\"/\\\"}"
      exe="${exe//\\/\\\\}"
      exe="${exe//\"/\\\"}"
      [[ "$first" -eq 1 ]] && first=0 || echo ","
      printf '  {"port": %s, "proto": "%s", "state": "%s", "pid": "%s", "process": "%s", "exe": "%s", "address": "%s"}' \
        "$port" "$proto" "$state" "$pid" "$process" "$exe" "$addr"
    done <<< "$ROWS"
    echo ""
    echo "]"
  }
  exit 0
fi

printf "%-7s %-6s %-10s %-8s %-16s %-24s %s\n" "PORT" "PROTO" "STATE" "PID" "PROCESS" "EXE" "ADDRESS"
while IFS=$'\t' read -r port proto state pid process addr; do
  exe="-"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || echo "-")"
  fi
  printf "%-7s %-6s %-10s %-8s %-16s %-24s %s\n" "$port" "$proto" "$state" "$pid" "$process" "$exe" "$addr"
done <<< "$ROWS"
