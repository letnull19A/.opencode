#!/usr/bin/env bash
# guard.sh — guardrail дизайна перед коммитом. Только чтение + проверка.
# Сверяет НЕЗАКОММИЧЕННЫЕ изменения UI-файлов с DESIGN.md:
#   error magic-color          hex/rgba-литерал в коде, которого нет в токенах DESIGN.md
#   error unregistered-component  новый компонент, не записанный в §3 DESIGN.md
#   error design-not-updated   есть design-нарушения, а сам DESIGN.md не тронут
#   warn  magic-px             px-литерал не из токенов (не блокирует, но виден)
# Пропускает: комментарии, *.test.* / *.spec.* / *.stories.*, строки с `design:ignore`.
#
# Использование (из корня consumer-репозитория):
#   bash .opencode/scripts/design/guard.sh [--staged] [--json]
#
#   без флагов  все незакоммиченные (staged+unstaged+untracked)
#   --staged    только staged
#   --json      только JSON на stdout (иначе JSON + human summary на stderr)
#
# Выход: stdout — только JSON {passed, violations[]}; stderr — summary.
# Коды: 0 — чисто (или нет UI-изменений), 1 — есть error-нарушения (коммит
# только после явного approve человека), 2 — нет DESIGN.md / не git.

set -euo pipefail

ONLY_STAGED=0
JSON_ONLY=0

usage() {
  echo "Usage: guard.sh [--staged] [--json]"
  echo "  Проверяет незакоммиченные UI-изменения против DESIGN.md."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staged) ONLY_STAGED=1; shift ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "design/guard: неизвестный аргумент '$1'" >&2
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
DESIGN="$ROOT/DESIGN.md"

if [[ ! -f "$DESIGN" ]]; then
  echo '{"passed":false,"error":"no_design_file","hint":"bash .opencode/scripts/design/init.sh","violations":[]}'
  echo "design/guard: нет DESIGN.md — сначала: bash .opencode/scripts/design/init.sh" >&2
  exit 2
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# UI-расширения: веб + мобилки. Тесты/сториз исключаем (зеркалят значения легально).
UI_RE='\.(tsx|jsx|css|scss|sass|less|vue|svelte|swift|kt|dart)$'
SKIP_RE='\.(test|spec|stories)\.[^.]+$'

cd "$ROOT"
if [[ "$ONLY_STAGED" -eq 1 ]]; then
  git diff --cached --name-only -z 2>/dev/null | tr '\0' '\n' > "$TMPDIR/changed.txt" || true
  : > "$TMPDIR/untracked.txt"
else
  git diff --name-only -z HEAD 2>/dev/null | tr '\0' '\n' > "$TMPDIR/changed.txt" || true
  git ls-files --others --exclude-standard -z 2>/dev/null | tr '\0' '\n' > "$TMPDIR/untracked.txt" || true
fi

grep -E "$UI_RE" "$TMPDIR/changed.txt" 2>/dev/null | grep -vE "$SKIP_RE" | sort -u > "$TMPDIR/ui.txt" || true
grep -E "$UI_RE" "$TMPDIR/untracked.txt" 2>/dev/null | grep -vE "$SKIP_RE" | sort -u > "$TMPDIR/ui_new.txt" || true

# DESIGN.md тронут в этой же пачке? (тогда freshness-чек пропускаем)
DESIGN_TOUCHED=0
if grep -qxF "DESIGN.md" "$TMPDIR/changed.txt" 2>/dev/null || grep -qxF "DESIGN.md" "$TMPDIR/untracked.txt" 2>/dev/null; then
  DESIGN_TOUCHED=1
fi
# путь может быть подпапкой — проверяем и суффикс
if [[ "$DESIGN_TOUCHED" -eq 0 ]]; then
  if grep -E '(^|/)DESIGN\.md$' "$TMPDIR/changed.txt" "$TMPDIR/untracked.txt" 2>/dev/null | grep -q .; then
    DESIGN_TOUCHED=1
  fi
fi

# Дифф добавленных строк с номерами (tracked), untracked — целиком.
: > "$TMPDIR/added.tsv"
if [[ -s "$TMPDIR/ui.txt" ]]; then
  # shellcheck disable=SC2086
  git diff -U0 HEAD -- $(cat "$TMPDIR/ui.txt") 2>/dev/null | python3 -c '
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
if [[ -s "$TMPDIR/ui_new.txt" ]]; then
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    awk -v F="$f" '{print F"\t"NR"\t"$0}' "$f" >> "$TMPDIR/added.tsv"
  done < "$TMPDIR/ui_new.txt"
fi

GUARD_JSON="$TMPDIR/guard.json"
python3 - "$TMPDIR/added.tsv" "$DESIGN" "$DESIGN_TOUCHED" "$GUARD_JSON" << 'PY'
import json, re, sys
added_path, design_path, out_path = sys.argv[1], sys.argv[2], sys.argv[4]
touched = sys.argv[3] == "1"

design = open(design_path, encoding="utf-8").read()
design_low = design.lower()

def norm_color(s):
    return re.sub(r"\s+", "", s.lower())

allowed_colors = {norm_color(m) for m in
                  re.findall(r"#[0-9a-fA-F]{3,8}\b", design) +
                  re.findall(r"rgba?\([^)]*\)", design, re.I)}
allowed_px = set(re.findall(r"(?<![\w.])(\d+(?:\.\d+)?px)", design))

HEX_RE = re.compile(r"#[0-9a-fA-F]{3,4}\b|#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{8}\b")
RGBA_RE = re.compile(r"rgba?\([^)]*\)", re.I)
PX_RE = re.compile(r"(?<![\w.])(\d+(?:\.\d+)?px)")
COMP_RE = re.compile(
    r"export\s+(?:default\s+)?(?:function|const|class|abstract\s+class)\s+([A-Z][A-Za-z0-9_]*)"
    r"|(?:function|const)\s+([A-Z][A-Za-z0-9_]*)\s*[=(]"
    r"|\b(?:class|struct)\s+([A-Z][A-Za-z0-9_]*)")
COMMENT_RE = re.compile(r"^\s*(//|\*|#|<!--|\"\"\"|''')")

violations = []
ui_files = set()
try:
    added = open(added_path, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    added = []

for entry in added:
    parts = entry.split("\t", 2)
    if len(parts) != 3:
        continue
    f, lno, code = parts
    ui_files.add(f)
    if "design:ignore" in code:
        continue
    if COMMENT_RE.match(code):
        continue
    for m in HEX_RE.findall(code) + RGBA_RE.findall(code):
        if norm_color(m) not in allowed_colors:
            violations.append({"file": f, "line": int(lno), "severity": "error",
                               "rule": "magic-color",
                               "message": f"магический цвет {m} — вынеси в токены DESIGN.md (§2)"})
    for m in PX_RE.findall(code):
        if m not in allowed_px:
            violations.append({"file": f, "line": int(lno), "severity": "warn",
                               "rule": "magic-px",
                               "message": f"магический размер {m} — добавь токен в DESIGN.md (§2) или design:ignore"})
    for grp in COMP_RE.findall(code):
        name = next((g for g in grp if g), "")
        if name and name not in design:
            violations.append({"file": f, "line": int(lno), "severity": "error",
                               "rule": "unregistered-component",
                               "message": f"компонент {name} не зарегистрирован в DESIGN.md (§3)"})

errors = [v for v in violations if v["severity"] == "error"]
if errors and not touched:
    violations.append({"file": "DESIGN.md", "line": 0, "severity": "error",
                       "rule": "design-not-updated",
                       "message": "есть design-нарушения, а DESIGN.md не обновлён — предложи человеку точные правки (токены/компоненты/журнал §6); правит только владелец, коммит после его approve"})

passed = not any(v["severity"] == "error" for v in violations)
out = {"design_file": design_path, "ui_files": sorted(ui_files),
       "design_touched": touched, "passed": passed,
       "violations": violations,
       "summary": ("design guard passed" if passed
                   else f"design guard: {len([v for v in violations if v['severity']=='error'])} errors") +
                  (f" in {len(ui_files)} UI files" if ui_files else " (no UI changes)")}
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
  echo "design/guard: есть error-нарушения — коммит только после явного approve человека" >&2
  exit 1
fi

