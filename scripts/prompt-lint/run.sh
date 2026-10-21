#!/usr/bin/env bash
# run.sh — линтер промптов: ловит в agents/skills/commands примеры запрещённых
# форм, которые агенты копируют (то, что пропустил человеческий аудит).
#
# Сканирует построчно:
#   <root>/agents/*.md
#   <root>/skills/*/SKILL.md
#   <root>/commands/*.md
# default root — корень consumer-репо через git rev-parse --show-toplevel.
#
# Флаги-нарушения (только внутри бектиковых спанов, построчно;
# просто упоминание слов без бектиков не флагается;
# спаны содержащие `${{` пропускаются ВО ВСЕХ правилах R1–R4 — GitHub Actions expressions, не shell):
#   R1 pipes: span matches `[^`]*\|\s*(head|tail|grep|awk|sed|cut|sort|xargs|tee)\b
#      — пайп именно в команду. Прозаические `|` без команды не флагать.
#      пример да: `cmd 2>&1 | head -20`; пример нет: `AKIA|sk-live`, «без пайпов».
#   R2 chains: span содержит `&&` или `||` И (начинается с известной команды
#      `^(git|bash|docker|npm|pnpm|npx|bun|make|cat|ls|cd|gh|curl|python3|pytest|go|cargo|echo|mkdir|rm|cp|mv|tree)\s`
#      ИЛИ содержит `--` ИЛИ содержит `/`).
#      Голые `stage_a && stage_b`, `need_deploy && deploy_host`, `${{a||b}}`,
#      сами запреты «без `&&`» — не флагать.
#   R3 bare git: ТОЛЬКО точный голый спан `git (status|log|diff|branch|rev-parse)`
#      (между бектиками ничего кроме команды).
#      `git diff HEAD`, `git log --oneline`, `a/b`-списки, `-D`-флаги — не флагать.
#   R4 raw gh: `gh\s+pr\b` без изменений.
#
# Пропуски (не нарушения):
#   - строки содержащие → (таблицы замен «было → стало»)
#   - спаны содержащие `${{` (GitHub Actions expressions — не shell) ВО ВСЕХ правилах R1–R4
#   - строки содержащие ЛЮБУЮ подстроку из waivers.txt (файл рядом,
#     по одной подстроке на строку, сравнение literal contains)
#
# Использование:
#   bash .opencode/scripts/prompt-lint/run.sh [--root <path>] [--json]
#
#   --root <path>  корень для сканирования (для тестов); default — git toplevel
#   --json         только JSON на stdout (иначе JSON + human hint на stderr)
#
# Выход: stdout — всегда JSON {"violations":[{"file","line","text"}],"count"}.
# stderr — human hint (тихо при --json).
# Коды: 0 — чисто, 1 — есть нарушения, 2 — ошибка использования/нет каталогов.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAIVERS_FILE="$SCRIPT_DIR/waivers.txt"

ROOT=""
JSON_ONLY=0

usage() {
  echo "Usage: run.sh [--root <path>] [--json]"
  echo "  Сканирует agents/*.md, skills/*/SKILL.md, commands/*.md на запрещённые формы."
  echo "  --root <path> — корень сканирования (default: git rev-parse --show-toplevel)"
  echo "  --json        — только JSON на stdout, без human hint в stderr"
}

emit_error_json() {
  # $1 — код ошибки для stderr-текста (machine-readable)
  printf '{"violations":[],"count":0,"error":"%s"}\n' "$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      if [[ $# -lt 2 ]]; then
        emit_error_json "missing_root_value"
        echo "prompt-lint: --root требует значение <path>" >&2
        usage >&2
        exit 2
      fi
      ROOT="$2"; shift 2 ;;
    --root=*)
      ROOT="${1#--root=}"; shift ;;
    --json)
      JSON_ONLY=1; shift ;;
    -h|--help)
      usage
      exit 0 ;;
    *)
      emit_error_json "bad_usage"
      echo "prompt-lint: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$ROOT" ]]; then
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    emit_error_json "not_git_repo"
    echo "prompt-lint: не git-репозиторий — укажи --root <path>" >&2
    exit 2
  fi
  ROOT="$(git rev-parse --show-toplevel)"
fi

if [[ ! -d "$ROOT" ]]; then
  emit_error_json "bad_root"
  echo "prompt-lint: нет каталога '$ROOT'" >&2
  exit 2
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
OUT_JSON="$TMPDIR/out.json"

python3 - "$ROOT" "$WAIVERS_FILE" "$OUT_JSON" << 'PY'
import glob
import json
import os
import re
import sys

root, waivers_path, out_path = sys.argv[1:4]

def load_waivers(p):
    try:
        with open(p, encoding="utf-8") as fh:
            subs = [l.rstrip("\r\n") for l in fh]
        # пустые строки игнорируем: пустая подстрока матчится везде
        return [s for s in subs if s != ""]
    except FileNotFoundError:
        return []

waivers = load_waivers(waivers_path)

patterns = [
    os.path.join(root, "agents", "*.md"),
    os.path.join(root, "skills", "*", "SKILL.md"),
    os.path.join(root, "commands", "*.md"),
]
files = []
for pat in patterns:
    files.extend(glob.glob(pat))
files = sorted({f for f in files if os.path.isfile(f)})

if not files:
    with open(out_path, "w", encoding="utf-8") as o:
        o.write(json.dumps({"violations": [], "count": 0,
                             "error": "no_scanned_files"}, ensure_ascii=False))
    sys.exit(0)

R1 = re.compile(r"`[^`]*\|\s*(head|tail|grep|awk|sed|cut|sort|xargs|tee)\b")
R4 = re.compile(r"`gh\s+pr\b")
SPAN_RE = re.compile(r"`[^`]*`")
R3_EXACT = re.compile(r"^`git (status|log|diff|branch|rev-parse)`$")
KNOWN_CMD = re.compile(r"^(git|bash|docker|npm|pnpm|npx|bun|make|cat|ls|cd|gh|curl|python3|pytest|go|cargo|echo|mkdir|rm|cp|mv|tree)\s")

violations = []
for f in files:
    try:
        with open(f, encoding="utf-8", errors="ignore") as fh:
            lines = fh.read().splitlines()
    except (IsADirectoryError, OSError):
        continue
    rel = os.path.relpath(f, root)
    for i, raw in enumerate(lines, 1):
        # Пропуски: стрелка замен и любая waiver-подстрока (literal contains).
        if "→" in raw:
            continue
        if any(w in raw for w in waivers):
            continue
        hit = False
        for m in SPAN_RE.finditer(raw):
            span = m.group(0)
            if "${{" in span:
                continue
            if R1.search(span):
                hit = True
                break
            if R4.search(span):
                hit = True
                break
            if R3_EXACT.search(span):
                hit = True
                break
            if "&&" in span or "||" in span:
                inner = span[1:-1]
                if KNOWN_CMD.search(inner) or "--" in inner or "/" in inner:
                    hit = True
                    break
        if hit:
            violations.append({"file": rel, "line": i, "text": raw.strip()[:500]})

with open(out_path, "w", encoding="utf-8") as o:
    o.write(json.dumps({"violations": violations, "count": len(violations)},
                       ensure_ascii=False, indent=2))
PY

# stdout — только JSON
cat "$OUT_JSON"

# Ошибка сканирования (нет файлов) — всегда exit 2, даже при --json.
if python3 -c 'import json,sys; sys.exit(0 if "error" in json.load(open(sys.argv[1],encoding="utf-8")) else 1)' "$OUT_JSON"; then
  if [[ "$JSON_ONLY" -eq 0 ]]; then
    python3 -c 'import json,sys; j=json.load(open(sys.argv[1],encoding="utf-8")); print("prompt-lint: нет файлов для сканирования (agents/*.md, skills/*/SKILL.md, commands/*.md)", file=sys.stderr)' "$OUT_JSON"
  fi
  exit 2
fi

if [[ "$JSON_ONLY" -eq 0 ]]; then
  python3 -c '
import json,sys
j=json.load(open(sys.argv[1],encoding="utf-8"))
n=j["count"]
if n == 0:
    print("prompt-lint: чисто (0 нарушений)", file=sys.stderr)
else:
    print(f"prompt-lint: {n} нарушений:", file=sys.stderr)
    for v in j["violations"]:
        print(f"  {v[\"file\"]}:{v[\"line\"]}: {v[\"text\"][:200]}", file=sys.stderr)
' "$OUT_JSON"
fi

if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1],encoding="utf-8"))["count"]==0 else 1)' "$OUT_JSON"; then
  exit 0
else
  if [[ "$JSON_ONLY" -eq 0 ]]; then
    echo "prompt-lint: есть нарушения — правь промпт, не waivers" >&2
  fi
  exit 1
fi
