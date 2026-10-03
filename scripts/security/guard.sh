#!/usr/bin/env bash
# guard.sh — guardrail безопасности I/O перед коммитом. Только чтение + проверка.
# Сверяет НЕЗАКОММИЧЕННЫЕ изменения кода (фронт + бэк) с базовыми правилами:
#   error dangerous-sink   XSS/RCE-приёмник без санитизации: dangerouslySetInnerHTML,
#                          innerHTML=, eval(, new Function(, os.system(, shell=True
#   warn  sql-concat       SQL собран конкатенацией/f-строкой вместо параметров
#   warn  unvalidated-input API-хендлер (route/controller/handler) без валидатора
#                          (zod/safeParse/pydantic/validate/DTO/schema) в scope
#   warn  unvalidated-form  форма/инпут во фронте без валидации (resolver/schema/validate)
# Конвенция выходов (фронт: валидируй на границе форм тем же schemas, что и API;
# бэк: валидируй вход schemas + сериализуй выход через них же, никогда сырые
# строки БД наружу) — в README.md; guard проверяет вход и явные sinks.
# Пропускает: комментарии, тесты/моки/сиды/фикстуры/сториз, строки с `sec:ignore`.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/security/guard.sh [--staged] [--json]
#
#   без флагов  все незакоммиченные (staged+unstaged+untracked)
#   --staged    только staged
#   --json      только JSON на stdout (иначе JSON + human summary на stderr)
#
# Выход: stdout — только JSON {passed, violations[]}; stderr — summary.
# Коды: 0 — чисто (или нет кодовых изменений), 1 — есть error-нарушения
# (коммит только после явного approve человека), 2 — не git-репозиторий.

set -euo pipefail

ONLY_STAGED=0
JSON_ONLY=0

usage() {
  echo "Usage: guard.sh [--staged] [--json]"
  echo "  Проверяет незакоммиченные изменения: sinks + валидация входа."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staged) ONLY_STAGED=1; shift ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "security/guard: неизвестный аргумент '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo '{"passed":false,"error":"not_git_repo","violations":[]}'
  exit 2
fi
ROOT="$(git rev-parse --show-toplevel)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

CODE_RE='\.(ts|tsx|js|jsx|mjs|cjs|py|go|rb|php|java)$'
SKIP_RE='\.(test|spec|stories|mock|seed|fixture|fixtures)\.[^.]+$|__(tests|mocks|fixtures)__|\.story\.'

cd "$ROOT"
if [[ "$ONLY_STAGED" -eq 1 ]]; then
  git diff --cached --name-only -z 2>/dev/null | tr '\0' '\n' > "$TMPDIR/changed.txt" || true
  : > "$TMPDIR/untracked.txt"
else
  git diff --name-only -z HEAD 2>/dev/null | tr '\0' '\n' > "$TMPDIR/changed.txt" || true
  git ls-files --others --exclude-standard -z 2>/dev/null | tr '\0' '\n' > "$TMPDIR/untracked.txt" || true
fi

grep -E "$CODE_RE" "$TMPDIR/changed.txt" 2>/dev/null | grep -vE "$SKIP_RE" | sort -u > "$TMPDIR/code.txt" || true
grep -E "$CODE_RE" "$TMPDIR/untracked.txt" 2>/dev/null | grep -vE "$SKIP_RE" | sort -u > "$TMPDIR/code_new.txt" || true

# Добавленные строки с номерами: tracked — из диффа, untracked — целиком.
: > "$TMPDIR/added.tsv"
if [[ -s "$TMPDIR/code.txt" ]]; then
  # shellcheck disable=SC2086
  git diff -U0 HEAD -- $(cat "$TMPDIR/code.txt") 2>/dev/null | python3 -c '
import sys
cur, line = None, 0
for raw in sys.stdin:
    if raw.startswith("+++ b/"):
        cur = raw[len("+++ b/"):].rstrip("\n")
        line = 0
    elif raw.startswith("@@"):
        try:
            part = raw.split("+", 1)[1]
            line = int(part.split(",")[0]) - 1
        except Exception:
            line = 0
    elif raw.startswith("+") and not raw.startswith("+++"):
        line += 1
        sys.stdout.write(f"{cur}\t{line}\t{raw[1:]}")
' >> "$TMPDIR/added.tsv" || true
fi
if [[ -s "$TMPDIR/code_new.txt" ]]; then
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    awk -v F="$f" '{print F"\t"NR"\t"$0}' "$f" >> "$TMPDIR/added.tsv"
  done < "$TMPDIR/code_new.txt"
fi

GUARD_JSON="$TMPDIR/guard.json"
python3 - "$TMPDIR/added.tsv" "$TMPDIR/code.txt" "$TMPDIR/code_new.txt" "$ROOT" "$GUARD_JSON" << 'PY'
import json, re, sys, os
added_path, tracked_path, new_path, root, out_path = sys.argv[1:6]

def read_list(p):
    try:
        return [l.strip() for l in open(p, encoding="utf-8") if l.strip()]
    except FileNotFoundError:
        return []

tracked, new_files = read_list(tracked_path), read_list(new_path)
code_files = tracked + new_files

SINK_RES = [
    (re.compile(r"dangerouslySetInnerHTML"), "dangerouslySetInnerHTML без санитизации (DOMPurify/sanitize)"),
    (re.compile(r"\.innerHTML\s*="), "прямая запись innerHTML без санитизации"),
    (re.compile(r"(?<![\w.])eval\s*\("), "eval() — произвольный код из строки"),
    (re.compile(r"new\s+Function\s*\("), "new Function() — произвольный код из строки"),
    (re.compile(r"(?<![\w.])exec\s*\("), "exec() — выполнение строки как кода"),
    (re.compile(r"os\.system\s*\("), "os.system() — шелл из строки"),
    (re.compile(r"shell\s*=\s*True"), "shell=True — инъекция через шелл"),
]
SQL_RE = re.compile(r"(f['\"]\s*SELECT|(execute|query|raw)\s*\(\s*f['\"]|(execute|query|raw)\s*\(\s*['\"][^'\"]*['\"]\s*\+|\"\s*\+\s*.*SELECT|SELECT.*\"\s*\+)", re.I)
VALIDATOR_RES = [
    "zod", "safeparse", ".parse(", "pydantic", "basemodel",
    "validate", "validator", "dto", "schema", "class-validator", "joi", "yup",
    "marshmallow", "serializer", "formrequest", "go-playground",
]
HANDLER_RE = re.compile(
    r"@app\.(get|post|put|patch|delete)|@(get|post|put|patch|delete|route)\b"
    r"|app\.(get|post|put|patch|delete)\s*\(|router\.(get|post|put|patch|delete)\s*\("
    r"|(async\s+)?def\s+\w+\s*\([^)]*request[^)]*\)|export\s+(async\s+)?function\s+(GET|POST|PUT|PATCH|DELETE)\b"
    r"|functions\.https|onRequest|onCall", re.I)
FORM_RE = re.compile(r"<form\b|onSubmit\s*=|useForm\s*\(|Formik\b", re.I)
COMMENT_RE = re.compile(r"^\s*(//|\*|#|<!--|\"\"\"|''')")

violations, seen_file_warn = [], set()

def file_text(path):
    try:
        with open(os.path.join(root, path), encoding="utf-8", errors="ignore") as fh:
            return fh.read()
    except (FileNotFoundError, IsADirectoryError):
        return ""

file_cache = {}
def cached_text(path):
    if path not in file_cache:
        file_cache[path] = file_text(path)
    return file_cache[path]

def has_validator(scope_text):
    low = scope_text.lower()
    return any(v in low for v in VALIDATOR_RES)

def warn_once(path, rule, message):
    key = (path, rule)
    if key in seen_file_warn:
        return
    seen_file_warn.add(key)
    violations.append({"file": path, "line": 0, "severity": "warn",
                       "rule": rule, "message": message})

try:
    added = open(added_path, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    added = []

for entry in added:
    parts = entry.split("\t", 2)
    if len(parts) != 3:
        continue
    f, lno, code = parts
    if "sec:ignore" in code:
        continue
    if COMMENT_RE.match(code):
        continue
    for rx, msg in SINK_RES:
        if rx.search(code):
            violations.append({"file": f, "line": int(lno), "severity": "error",
                               "rule": "dangerous-sink", "message": msg})
    if SQL_RE.search(code):
        violations.append({"file": f, "line": int(lno), "severity": "warn",
                           "rule": "sql-concat",
                           "message": "SQL собран конкатенацией/f-строкой — используй параметры (sec:ignore если значение не из входа)"})

# Пофайловые warn-проверки: хендлер/форма без валидатора в scope.
for f in code_files:
    text = cached_text(f)
    if not text:
        continue
    low = text.lower()
    is_api = ("route" in f.lower() or "controller" in f.lower() or "handler" in f.lower()
              or "/api/" in f.lower() or "views" in f.lower() or "router" in f.lower()
              or bool(HANDLER_RE.search(text)))
    if is_api and not has_validator(text):
        warn_once(f, "unvalidated-input",
                  "API-слой без валидатора входа — добавь schema (zod/pydantic/DTO) на границе")
    if re.search(r"\.(tsx|jsx)$", f) and FORM_RE.search(text) and not has_validator(text):
        warn_once(f, "unvalidated-form",
                  "форма без валидации — добавь resolver/schema (тем же schemas, что API)")

errors = [v for v in violations if v["severity"] == "error"]
passed = not errors
ui_note = f" in {len(set(v['file'] for v in violations))} files" if violations else ""
out = {"passed": passed, "files": sorted(set(tracked) | set(new_files)),
       "violations": violations,
       "summary": ("security guard passed" if passed
                   else f"security guard: {len(errors)} errors") +
                  (f" ({len(code_files)} code files checked)" if code_files else " (no code changes)")}
open(out_path, "w", encoding="utf-8").write(json.dumps(out, ensure_ascii=False, indent=2))
PY

# stdout — только JSON; stderr — human summary
cat "$GUARD_JSON"
if [[ "$JSON_ONLY" -eq 0 ]]; then
  python3 -c 'import json,sys; j=json.load(open(sys.argv[1],encoding="utf-8")); print("summary: "+j["summary"], file=sys.stderr);
for v in j["violations"]:
    print("  " + v["severity"] + " " + v["rule"] + " " + v["file"] + ":" + str(v["line"]) + " - " + v["message"], file=sys.stderr)' "$GUARD_JSON"
fi

if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1],encoding="utf-8"))["passed"] else 1)' "$GUARD_JSON"; then
  exit 0
else
  echo "security/guard: есть error-нарушения — коммит только после явного approve человека" >&2
  exit 1
fi
