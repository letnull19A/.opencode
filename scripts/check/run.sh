#!/usr/bin/env bash
# run.sh — проверки только для незакоммиченных файлов (экономия памяти).
# Запускает typecheck / eslint (oxlint) / prettier только на изменённых файлах
# и выводит результат в JSON, понятном ИИ-агенту.
#
# Использование (из корня репо):
#   bash .opencode/scripts/check/run.sh [--typecheck] [--lint] [--format] [--all]
#   bash .opencode/scripts/check/run.sh --help
#
# По умолчанию запускает все три проверки, если есть файлы для них.
#   --typecheck  только typecheck
#   --lint       только lint (oxlint/eslint)
#   --format     только prettier/oxfmt
#   --all        то же что без флагов — все проверки
#   --json       только JSON на stdout (по умолчанию JSON + human summary на stderr)
#   --staged     только staged (git diff --cached), по умолчанию все незакоммиченные (staged+unstaged+untracked)
#
# Выход: stdout — только JSON, stderr — человеко-читаемый summary + детали.
# Exit code: 0 если всё прошло, 1 если есть ошибки, 2 если нет файлов.

set -euo pipefail

# ---------- args ----------
DO_TYPECHECK=0; DO_LINT=0; DO_FORMAT=0; ONLY_STAGED=0; JSON_ONLY=0
if [[ $# -eq 0 ]]; then
  DO_TYPECHECK=1; DO_LINT=1; DO_FORMAT=1
else
  for arg in "$@"; do
    case "$arg" in
      --typecheck) DO_TYPECHECK=1 ;;
      --lint) DO_LINT=1 ;;
      --format|--prettier|--fmt) DO_FORMAT=1 ;;
      --all) DO_TYPECHECK=1; DO_LINT=1; DO_FORMAT=1 ;;
      --staged) ONLY_STAGED=1 ;;
      --json) JSON_ONLY=1 ;;
      -h|--help)
        echo "Usage: run.sh [--typecheck] [--lint] [--format] [--staged] [--json]"
        echo "  По умолчанию — все проверки на незакоммиченных файлах (staged+unstaged+untracked)."
        echo "  --staged — только staged, --json — только JSON на stdout"
        exit 0
        ;;
      *) echo "check: неизвестный аргумент '$arg' — см. --help" >&2; exit 1 ;;
    esac
  done
  # если ни один флаг проверки не выбран явно, но выбран --staged/--json — считаем что все
  if [[ $DO_TYPECHECK -eq 0 && $DO_LINT -eq 0 && $DO_FORMAT -eq 0 ]]; then
    DO_TYPECHECK=1; DO_LINT=1; DO_FORMAT=1
  fi
fi

# ---------- git root & changed files ----------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo '{"error":"not_git_repo","hint":"запусти из git-репозитория"}'
  exit 2
fi
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Собираем незакоммиченные файлы: staged+unstaged (HEAD) + untracked
if [[ $ONLY_STAGED -eq 1 ]]; then
  git diff --name-only --cached -z 2>/dev/null | tr '\0' '\n' > "$TMPDIR/changed_raw.txt" || true
else
  git diff --name-only -z HEAD 2>/dev/null | tr '\0' '\n' > "$TMPDIR/changed_raw.txt" || true
  git ls-files --others --exclude-standard -z 2>/dev/null | tr '\0' '\n' >> "$TMPDIR/changed_raw.txt" || true
fi

# Фильтруем: только существующие файлы (удалённые пропускаем), без дублей, сортировка
> "$TMPDIR/changed.txt"
if [[ -s "$TMPDIR/changed_raw.txt" ]]; then
  sort -u "$TMPDIR/changed_raw.txt" | while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] || continue
    # отбрасываем бинарные/большие артефакты
    case "$f" in
      *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.woff*|*.ttf|*.eot|*.mp4|*.mp3|*.pdf|*.zip|*.tar.gz) continue ;;
    esac
    echo "$f" >> "$TMPDIR/changed.txt"
  done
fi

if [[ ! -s "$TMPDIR/changed.txt" ]]; then
  JSON='{"files":[],"totals":{"typecheck":{"passed":true,"errors":0},"lint":{"passed":true,"errors":0},"format":{"passed":true,"errors":0}},"typecheck":[],"lint":[],"format":[],"summary":"no changed files"}'
  echo "$JSON"
  [[ $JSON_ONLY -eq 0 ]] && echo "check: нет изменённых файлов" >&2
  exit 0
fi

# Разделяем по расширениям
grep -E '\.(ts|tsx|mts|cts)$' "$TMPDIR/changed.txt" > "$TMPDIR/ts.txt" || true
grep -E '\.(ts|tsx|js|jsx|mjs|cjs|mts|cts)$' "$TMPDIR/changed.txt" > "$TMPDIR/lint.txt" || true
grep -E '\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|json|css|scss|md|yaml|yml)$' "$TMPDIR/changed.txt" > "$TMPDIR/fmt.txt" || true

# ---------- helpers ----------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- typecheck ----------
TC_ERRORS="$TMPDIR/tc.json"
echo "[]" > "$TC_ERRORS"
TC_PASSED=true
TC_COUNT=0
if [[ $DO_TYPECHECK -eq 1 && -s "$TMPDIR/ts.txt" ]]; then
  # Пробуем per-file typecheck для экономии памяти (если файлов <=10), иначе full но фильтруем
  mapfile -t TS_FILES < "$TMPDIR/ts.txt"
  TC_TMP="$TMPDIR/tc_raw.txt"; > "$TC_TMP"
  if [[ ${#TS_FILES[@]} -le 12 ]]; then
    # per-file: npx tsc --noEmit --pretty false <file> (использует ближайший tsconfig)
    for f in "${TS_FILES[@]}"; do
      # находим ближайший tsconfig
      DIR="$(dirname "$f")"
      TSCONFIG=""
      while [[ "$DIR" != "." && "$DIR" != "/" ]]; do
        if [[ -f "$DIR/tsconfig.json" ]]; then TSCONFIG="$DIR/tsconfig.json"; break; fi
        DIR="$(dirname "$DIR")"
      done
      [[ -z "$TSCONFIG" && -f "tsconfig.json" ]] && TSCONFIG="tsconfig.json"
      if has_cmd npx; then
        if [[ -n "$TSCONFIG" ]]; then
          npx --yes tsc -p "$TSCONFIG" --noEmit --pretty false 2>&1 | grep -F "$f" >> "$TC_TMP" || true
          # fallback per-file если -p не дал ошибок для этого файла
          if ! grep -q -F "$f" "$TC_TMP" 2>/dev/null; then
            npx --yes tsc --noEmit --pretty false --skipLibCheck "$f" 2>&1 | cat >> "$TC_TMP" || true
          fi
        else
          npx --yes tsc --noEmit --pretty false --skipLibCheck "$f" 2>&1 | cat >> "$TC_TMP" || true
        fi
      fi
    done
  else
    # много файлов — один прогон tsc в корне, потом фильтруем
    if has_cmd npx; then
      npx --yes tsc --noEmit --pretty false 2>&1 | grep -F -f "$TMPDIR/ts.txt" > "$TC_TMP" || true
      # если grep не дал результатов но tsc падал — сохраняем всё (чтобы не потерять ошибки)
      if [[ ! -s "$TC_TMP" ]]; then
        npx --yes tsc --noEmit --pretty false 2>&1 > "$TC_TMP" || true
        # фильтруем только строки с ошибками в changed файлах
        grep -F -f "$TMPDIR/ts.txt" "$TC_TMP" > "$TC_TMP.filtered" 2>/dev/null || true
        if [[ -s "$TC_TMP.filtered" ]]; then mv "$TC_TMP.filtered" "$TC_TMP"; fi
      fi
    fi
  fi
  # Парсим tsc вывод: file(line,col): error TSxxxx: message
  python3 - "$TC_TMP" "$TMPDIR/ts.txt" "$TC_ERRORS" << 'PY'
import re, json, sys, pathlib
tc_path, changed_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    changed = set(l.strip() for l in open(changed_path, encoding='utf-8') if l.strip())
except: changed = set()
# tsc: src/foo.ts(12,5): error TS2322: ...
re_tc = re.compile(r'^(.*?)\((\d+),(\d+)\):\s*error\s+(TS\d+):\s*(.*)$')
errors=[]
try:
    for line in open(tc_path, encoding='utf-8', errors='ignore'):
        m=re_tc.match(line.strip())
        if not m: continue
        f, l, c, code, msg = m.groups()
        # нормализуем путь
        f_norm = f.lstrip('./')
        # оставляем только если файл в changed (или его импорт — но фильтруем строго)
        if f_norm in changed or any(f_norm.endswith('/'+x) or f_norm==x for x in changed):
            errors.append({"file": f_norm, "line": int(l), "column": int(c), "code": code, "message": msg, "raw": line.strip()})
        elif not changed:
            errors.append({"file": f_norm, "line": int(l), "column": int(c), "code": code, "message": msg, "raw": line.strip()})
except FileNotFoundError:
    pass
with open(out_path,'w',encoding='utf-8') as o: json.dump(errors,o,ensure_ascii=False)
PY
  TC_COUNT="$(python3 -c 'import json; print(len(json.load(open("'"$TC_ERRORS"'",encoding="utf-8"))))' 2>/dev/null || echo 0)"
  [[ "$TC_COUNT" -eq 0 ]] && TC_PASSED=true || TC_PASSED=false
else
  echo "[]" > "$TC_ERRORS"
  TC_PASSED=true
fi

# ---------- lint (oxlint / eslint) ----------
LINT_ERRORS="$TMPDIR/lint.json"
echo "[]" > "$LINT_ERRORS"
LINT_PASSED=true
LINT_COUNT=0
if [[ $DO_LINT -eq 1 && -s "$TMPDIR/lint.txt" ]]; then
  LINT_TMP="$TMPDIR/lint_raw.json"
  LINT_TXT="$TMPDIR/lint_raw.txt"
  > "$LINT_TMP"; > "$LINT_TXT"
  if has_cmd npx; then
    # пробуем oxlint json
    if npx --yes oxlint --help >/dev/null 2>&1; then
      # oxlint --format json (если поддерживается) иначе plain
      set +e
      npx --yes oxlint --format json $(cat "$TMPDIR/lint.txt") > "$LINT_TMP" 2> "$LINT_TXT" || true
      set -e
      if [[ ! -s "$LINT_TMP" || "$(head -c 1 "$LINT_TMP")" != "[" && "$(head -c 1 "$LINT_TMP")" != "{" ]]; then
        # plain text fallback — каждый warning в отдельной строке
        npx --yes oxlint $(cat "$TMPDIR/lint.txt") > "$LINT_TXT" 2>&1 || true
        # парсим plain: file:line:col - message
        python3 - "$LINT_TXT" "$LINT_ERRORS" << 'PY'
import re, json, sys
src, out = sys.argv[1], sys.argv[2]
# oxlint plain: src/foo.ts:12:5 - warning ...
re_plain = re.compile(r'^(.*?):(\d+):(\d+)\s*[-:]\s*(.*)$')
errs=[]
for line in open(src, encoding='utf-8', errors='ignore'):
    line=line.strip()
    if not line: continue
    m=re_plain.match(line)
    if m:
        f,l,c,msg=m.groups()
        errs.append({"file": f, "line": int(l), "column": int(c), "message": msg, "raw": line})
    elif "error" in line.lower() or "warning" in line.lower():
        errs.append({"file": "", "line": 0, "column": 0, "message": line, "raw": line})
with open(out,'w',encoding='utf-8') as o: json.dump(errs,o,ensure_ascii=False)
PY
      else
        # json от oxlint — нормализуем
        python3 - "$LINT_TMP" "$LINT_ERRORS" << 'PY'
import json, sys
src, out = sys.argv[1], sys.argv[2]
try:
    data=json.load(open(src,encoding='utf-8'))
    # oxlint json может быть {"files": [...]} или [...]
    if isinstance(data, dict) and "files" in data:
        files=data["files"]
    elif isinstance(data, list):
        files=data
    else:
        files=[]
    errs=[]
    for f in files:
        fname=f.get("file") or f.get("path") or ""
        for m in f.get("messages") or f.get("errors") or []:
            errs.append({"file": fname, "line": m.get("line") or m.get("row") or 0, "column": m.get("column") or m.get("col") or 0, "message": m.get("message") or str(m), "rule": m.get("rule") or m.get("code") or "", "raw": json.dumps(m, ensure_ascii=False)})
    with open(out,'w',encoding='utf-8') as o: json.dump(errs,o,ensure_ascii=False)
except Exception as e:
    # fallback: сохраняем сырой вывод
    import pathlib
    raw=open(src,encoding='utf-8',errors='ignore').read()
    with open(out,'w',encoding='utf-8') as o: json.dump([{"file":"","message":raw[:4000],"raw":raw[:4000]}],o,ensure_ascii=False)
PY
      fi
    elif npx --yes eslint --help >/dev/null 2>&1; then
      npx --yes eslint --format json $(cat "$TMPDIR/lint.txt") > "$LINT_TMP" 2>&1 || true
      python3 - "$LINT_TMP" "$LINT_ERRORS" << 'PY'
import json, sys
src, out = sys.argv[1], sys.argv[2]
try:
    data=json.load(open(src,encoding='utf-8'))
    errs=[]
    for f in data:
        for m in f.get("messages",[]):
            errs.append({"file": f.get("filePath",""), "line": m.get("line",0), "column": m.get("column",0), "message": m.get("message",""), "rule": m.get("ruleId",""), "raw": f"{f.get('filePath')}:{m.get('line')}:{m.get('column')} {m.get('message')}"})
    with open(out,'w',encoding='utf-8') as o: json.dump(errs,o,ensure_ascii=False)
except:
    with open(out,'w',encoding='utf-8') as o: json.dump([],o,ensure_ascii=False)
PY
    fi
  fi
  LINT_COUNT="$(python3 -c 'import json; print(len(json.load(open("'"$LINT_ERRORS"'",encoding="utf-8"))))' 2>/dev/null || echo 0)"
  [[ "$LINT_COUNT" -eq 0 ]] && LINT_PASSED=true || LINT_PASSED=false
else
  echo "[]" > "$LINT_ERRORS"
  LINT_PASSED=true
fi

# ---------- format (prettier / oxfmt) ----------
FMT_ERRORS="$TMPDIR/fmt.json"
echo "[]" > "$FMT_ERRORS"
FMT_PASSED=true
FMT_COUNT=0
if [[ $DO_FORMAT -eq 1 && -s "$TMPDIR/fmt.txt" ]]; then
  FMT_TMP="$TMPDIR/fmt_raw.txt"; > "$FMT_TMP"
  if has_cmd npx; then
    # пробуем prettier
    if npx --yes prettier --help >/dev/null 2>&1; then
      # --list-different выводит список неотформатированных файлов
      set +e
      npx --yes prettier --check --list-different $(cat "$TMPDIR/fmt.txt") > "$FMT_TMP" 2>&1 || true
      set -e
      python3 - "$FMT_TMP" "$FMT_ERRORS" << 'PY'
import json, sys, pathlib
src, out = sys.argv[1], sys.argv[2]
lines=[l.strip() for l in open(src,encoding='utf-8',errors='ignore') if l.strip() and not l.strip().startswith('Checking')]
errs=[]
for l in lines:
    # prettier выводит пути неотформатированных файлов
    if l and not l.startswith('[') and not 'All matched' in l:
        # отбрасываем служебные строки
        if l.startswith('prettier') or l.startswith('Checking'): continue
        # каждая строка — файл
        for part in l.split():
            part=part.strip().strip(',')
            if part and ('.' in part):
                errs.append({"file": part, "message": "not formatted (prettier)", "raw": part})
# дедуп
seen=set(); uniq=[]
for e in errs:
    if e["file"] not in seen:
        seen.add(e["file"]); uniq.append(e)
with open(out,'w',encoding='utf-8') as o: json.dump(uniq,o,ensure_ascii=False)
PY
    elif npx --yes oxfmt --help >/dev/null 2>&1; then
      npx --yes oxfmt --check $(cat "$TMPDIR/fmt.txt") > "$FMT_TMP" 2>&1 || true
      python3 - "$FMT_TMP" "$FMT_ERRORS" << 'PY'
import json, sys
src, out = sys.argv[1], sys.argv[2]
errs=[{"file": l.strip(), "message": "not formatted (oxfmt)", "raw": l.strip()} for l in open(src,encoding='utf-8',errors='ignore') if l.strip()]
with open(out,'w',encoding='utf-8') as o: json.dump(errs,o,ensure_ascii=False)
PY
    fi
  fi
  FMT_COUNT="$(python3 -c 'import json; print(len(json.load(open("'"$FMT_ERRORS"'",encoding="utf-8"))))' 2>/dev/null || echo 0)"
  [[ "$FMT_COUNT" -eq 0 ]] && FMT_PASSED=true || FMT_PASSED=false
else
  echo "[]" > "$FMT_ERRORS"
  FMT_PASSED=true
fi

# ---------- итоговый JSON ----------
FILES_JSON="$(python3 -c 'import json; print(json.dumps([l.strip() for l in open("'"$TMPDIR/changed.txt"'",encoding="utf-8") if l.strip()], ensure_ascii=False))' 2>/dev/null || echo '[]')"

JSON_OUT="$(python3 - "$FILES_JSON" "$TC_ERRORS" "$LINT_ERRORS" "$FMT_ERRORS" << 'PY'
import json, sys
files=json.loads(sys.argv[1])
tc=json.load(open(sys.argv[2],encoding='utf-8'))
lint=json.load(open(sys.argv[3],encoding='utf-8'))
fmt=json.load(open(sys.argv[4],encoding='utf-8'))
tc_pass=len(tc)==0
lint_pass=len(lint)==0
fmt_pass=len(fmt)==0
all_pass=tc_pass and lint_pass and fmt_pass
if not files:
    summary="no changed files"
elif all_pass:
    summary=f"all checks passed ({len(files)} files)"
else:
    parts=[]
    if not tc_pass: parts.append(f"typecheck: {len(tc)} errors")
    if not lint_pass: parts.append(f"lint: {len(lint)} errors")
    if not fmt_pass: parts.append(f"format: {len(fmt)} files")
    summary=", ".join(parts) + f" in {len(files)} changed files"
out={
    "files": files,
    "totals": {
        "typecheck": {"passed": tc_pass, "errors": len(tc)},
        "lint": {"passed": lint_pass, "errors": len(lint)},
        "format": {"passed": fmt_pass, "errors": len(fmt)},
        "all_passed": all_pass
    },
    "typecheck": tc,
    "lint": lint,
    "format": fmt,
    "summary": summary,
    "hint": "typecheck/lint/format — массивы ошибок; files — проверенные незакоммиченные файлы; totals — сводка. Запускай только на changed файлах, экономит память."
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
)"

# stdout — только JSON
echo "$JSON_OUT"
if [[ $JSON_ONLY -eq 0 ]]; then
  python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print("summary: "+j["summary"], file=sys.stderr);
if j["typecheck"]: print(f"typecheck errors: {len(j[\"typecheck\"])}", file=sys.stderr)
if j["lint"]: print(f"lint errors: {len(j[\"lint\"])}", file=sys.stderr)
if j["format"]: print(f"format errors: {len(j[\"format\"])}", file=sys.stderr)
' "$JSON_OUT" 2>/dev/null || echo "summary: $(echo "$JSON_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["summary"])')" >&2
fi

# exit code: 0 если всё passed, 1 если есть ошибки
if python3 -c 'import json,sys; j=json.loads(open(sys.argv[1],encoding="utf-8").read()); sys.exit(0 if j["totals"]["all_passed"] else 1)' <(echo "$JSON_OUT") 2>/dev/null; then
  exit 0
else
  exit 1
fi
