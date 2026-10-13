#!/usr/bin/env bash
# guard.sh — guardrail дизайна перед коммитом. Только чтение + проверка.
# Сверяет НЕЗАКОММИЧЕННЫЕ изменения UI-файлов с DESIGN.md (style-guide: токены/box-shadow/dark/a11y):
#   error magic-color          hex/rgba-литерал в коде, которого нет в токенах DESIGN.md
#                              (внутри верхнеуровневых блоков токенов `:root`/`.dark`
#                               литерал — это само определение палитры, §2, и не
#                               проверяется; hex и rgb() нормализуются к одному канону)
#   error box-shadow           box-shadow в коде (запрещён §2/§5 — только border/outline)
#   error design-not-updated   есть design-нарушения, а сам DESIGN.md не тронут
#   warn  magic-px             px-литерал не из токенов (не блокирует, но виден)
# Пропускает: комментарии, *.test.* / *.spec.* / *.stories.*, строки с `design:ignore`.
#
# Монорепо: DESIGN.md резолвится PER-FILE — ближайший вверх по директориям
# (apps/<service>/DESIGN.md, services/<service>/DESIGN.md и т.д.), с фолбэком на
# корневой $ROOT/DESIGN.md. Токены = union сервисного + корневого.
# Файл, для которого не нашлось ни одного DESIGN.md, по дизайну не проверяется
# (помечается в JSON как files_without_design), чтобы не плодить ложные error'ы.
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
# только после явного approve человека), 2 — не git, либо НИ ОДНОГО DESIGN.md
# в репозитории (нет даже корневого).

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
ROOT_DESIGN="$ROOT/DESIGN.md"
# Корневой DESIGN.md — фолбэк/источник общих токенов, не единственный:
# резолюция per-file (ближайший вверх) делается в python-блоке. Поэтому
# отсутствие корневого файла — не ранний exit, а решение уже там.

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

# Какие DESIGN.md тронуты в этой же пачке? (список, не один флаг — freshness
# теперь проверяется per-design-файл, а не только по корню)
cat "$TMPDIR/changed.txt" "$TMPDIR/untracked.txt" 2>/dev/null \
  | grep -E '(^|/)DESIGN\.md$' | sort -u > "$TMPDIR/design_touched.txt" || true
[[ -s "$TMPDIR/design_touched.txt" ]] && DESIGN_TOUCHED=1 || DESIGN_TOUCHED=0

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
python3 - "$TMPDIR/added.tsv" "$ROOT" "$ROOT_DESIGN" "$TMPDIR/design_touched.txt" "$GUARD_JSON" "$ONLY_STAGED" << 'PY'
import json, os, re, subprocess, sys
from bisect import bisect_right

added_path = sys.argv[1]
ROOT = os.path.realpath(sys.argv[2])
root_design = sys.argv[3] if os.path.isfile(sys.argv[3]) else ""
touched_path = sys.argv[4]
out_path = sys.argv[5]
_staged = sys.argv[6] == "1"

def canon_color(s):
    """Канонический вид цвета: hex и rgb()/rgba() приводятся к ОДНОЙ форме.

    Зачем: палитра в DESIGN.md и её использование в коде записаны по-разному
    (`#fff` vs `rgb(255 255 255)`). Без нормализации эквивалентные записи
    ловятся как «магический цвет». Форма: `rgb(r,g,b)` для непрозрачных,
    `rgba(r,g,b,a)` для альфы (a в долях) — обе стороны проходят через
    один формат, поэтому сравнение честное.
    """
    t = re.sub(r"\s+", "", s).lower()
    m = re.fullmatch(r"#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})", t)
    if m:
        h = m.group(1)
        if len(h) in (3, 4):
            h = "".join(ch * 2 for ch in h)
        if len(h) not in (6, 8):
            return t  # некорректная длина (5/7 цифр) — сравниваем как есть
        r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
        a = int(h[6:8], 16) / 255 if len(h) == 8 else None
    else:
        m = re.fullmatch(r"rgba?\(([^)]*)\)", t)
        if not m:
            return t  # не цвет — вернуть как есть (сравнение не сойдётся)
        nums = [n for n in m.group(1).replace(",", " ").replace("/", " ").split(" ") if n]
        if len(nums) < 3:
            return t
        try:
            r, g, b = (int(float(n)) for n in nums[:3])
            a = float(nums[3]) if len(nums) > 3 else None
        except ValueError:
            return t  # проценты/мусор — не интерпретируем молча
    if a is None or a == 1:
        return f"rgb({r},{g},{b})"
    return f"rgba({r},{g},{b},{a:.6g})"


def norm_color(s):
    """Историческое имя — теперь это канонизация, а не lower()+trim."""
    return canon_color(s)

# --- резолюция DESIGN.md per-file: ближайший вверх, не выше $ROOT -------------
_dir_cache = {}
def resolve_design_dir(start_dir):
    """Ближайший DESIGN.md от start_dir вверх (включая сам start_dir), граница — ROOT."""
    if start_dir in _dir_cache:
        return _dir_cache[start_dir]
    cur = start_dir
    hit = ""
    while True:
        cand = os.path.join(cur, "DESIGN.md")
        if os.path.isfile(cand):
            hit = cand
            break
        if cur == ROOT:
            break
        parent = os.path.dirname(cur)
        if parent == cur or not parent.startswith(ROOT):
            break  # вышли за границу репозитория
        cur = parent
    _dir_cache[start_dir] = hit
    return hit

# --- разбор одного design-файла (кэш по пути: не читаем на каждую строку) ---
_design_cache = {}
def load_design(path):
    if path not in _design_cache:
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            text = ""
        colors = {norm_color(m) for m in
                  re.findall(r"#[0-9a-fA-F]{3,8}\b", text) +
                  re.findall(r"rgba?\([^)]*\)", text, re.I)}
        px = set(re.findall(r"(?<![\w.])(\d+(?:\.\d+)?px)", text))
        # текст хранится в исходном регистре: проверка имени компонента
        # регистрозависимая (PascalCase), lowercase-версия для неё непригодна.
        _design_cache[path] = (colors, px, text)
    return _design_cache[path]

def rules_for_file(f):
    """(allowed_colors, allowed_px, design_path) для файла f.

    Union: сервисный (ближайший) + корневой. Обоснование: корневой DESIGN.md —
    владелец общих токенов; сервисный — расширение/переопределение под сервис.
    Пересечение не конфликтует (это set-union литералов), а общие токены из корня
    не должны ломать легальный код сервиса. Приоритет сервисного достигается
    тем, что резолюция находит его ПЕРВЫМ — корневой используется, только если
    сервисного нет (тогда он и есть ближайший).
    """
    fdir = os.path.dirname(os.path.join(ROOT, f))
    nearest = resolve_design_dir(fdir)
    if nearest and os.path.realpath(nearest) == os.path.realpath(root_design or ""):
        nearest = ""  # ближайший и есть корневой — дублировать не надо
    paths = [p for p in (nearest, root_design) if p]
    if not paths:
        return set(), set(), ""
    colors, px = set(), set()
    for p in paths:
        c, x, _t = load_design(p)
        colors |= c
        px |= x
    return colors, px, paths[0]

_touched = set()
try:
    for line in open(touched_path, encoding="utf-8"):
        line = line.strip()
        if line:
            _touched.add(os.path.realpath(os.path.join(ROOT, line)))
except FileNotFoundError:
    pass

HEX_RE = re.compile(r"#[0-9a-fA-F]{3,4}\b|#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{8}\b")
RGBA_RE = re.compile(r"rgba?\([^)]*\)", re.I)
PX_RE = re.compile(r"(?<![\w.])(\d+(?:\.\d+)?px)")
BOX_RE = re.compile(r"box-shadow\s*:|boxShadow\s*:", re.I)
# Проверка unregistered-component удалена осознанно: в DESIGN.md нет
# конкретных компонентов — только абстракции (§3 template.md), поэтому
# сопоставлять имена объявлений не с чем. См. историю принципа в README.


# --- контекст файла: где именно лежит строка --------------------------------
_snapshot_cache = {}


def file_snapshot(rel):
    """Строки файла ИЗ ТОГО ЖЕ источника, из которого пришли номера строк
    added.tsv: при --staged это индекс (`git show :file`), иначе рабочее дерево.
    Кэш по пути — читаем один раз на файл, не на строку."""
    if rel in _snapshot_cache:
        return _snapshot_cache[rel]
    text = ""
    if _staged:
        try:
            p = subprocess.run(["git", "show", ":" + rel], cwd=ROOT,
                               capture_output=True, text=True, check=False)
            if p.returncode == 0:
                text = p.stdout
        except OSError:
            text = ""
    if not text:
        try:
            with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            text = ""
    lines = text.splitlines()
    _snapshot_cache[rel] = lines
    return lines


# По DESIGN.md §2 hex/rgba законны ровно в одном месте — блок объявления
# токенов: верхнеуровневый `:root {}` / `.dark {}`.
#
# `html` в список НЕ входит намеренно: это базовый reset, а не палитра —
# раньше он был источником молчаливых пропусков.
TOKEN_SEL_RE = re.compile(r"^:(?:root)$|^\.dark$")


def _is_token_selector(sel):
    """Токенный селектор — РОВНО ОДИН селектор из списка, без хвостов.

    Строго, без `any()` по запятой: `.card:hover, .dark` / `:root, .app-shell` /
    `html, body` — это НЕ блок палитры. Признак один токен где-то в списке не
    делает блок легальным, он лишь тихо легализует весь блок целиком.
    Строгость выбрана «наружу» (лишнее violation вместо молчаливой дыры).
    """
    s = sel.strip()
    if not s or "," in s:
        return False
    return TOKEN_SEL_RE.match(s) is not None


def token_block_spans(text):
    """Диапазоны (start, end) символьных смещений, где литерал — палитра.

    Диапазон = содержимое блока токенов МИНУС содержимое вложенных в него
    блоков. Диапазон эмитится только для ЗАКРЫТОГО блока: незакрытая скобка
    означает, что дальше границы блока неизвестны, поэтому весь остаток файла
    трактуется как обычный код (ловим лишнее, не теряем нарушения).

    Сканер учитывает комментарии `/* */` и строковые литералы: `{` внутри
    `content: "{"` не открывает блок и не ломает стек.
    """
    spans = []
    stack = []          # (is_token, content_start) по уровням вложенности
    token_open = None   # [start, [(s, e), ...]] — открытый блок токенов
    nested_start = None  # начало вложенного блока внутри блока токенов
    buf = ""
    i, n = 0, len(text)
    while i < n:
        if text.startswith("/*", i):
            e = text.find("*/", i + 2)
            if e == -1:
                break  # незакрытый комментарий — до конца файла, блок не эмитим
            i = e + 2
            continue
        if text[i] in "\"'":
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == text[i] or text[j] == "\n":
                    break
                j += 1
            i = j + 1  # содержимое строки не влияет на стек
            continue
        c = text[i]
        if c == "{":
            is_token = not stack and _is_token_selector(buf)
            stack.append((is_token, i + 1))
            if is_token:
                token_open = [i + 1, []]
            elif stack[:-1] and stack[-2][0]:
                nested_start = i + 1  # вложенный блок ВНУТРИ блока токенов
            buf = ""
        elif c == "}":
            if stack:
                is_token, _start = stack.pop()
                if is_token and token_open:
                    # Вырезаем содержимое вложенных блоков из диапазона палитры.
                    segs, cur = [], token_open[0]
                    for s0, e0 in token_open[1]:
                        if s0 > cur:
                            segs.append((cur, s0))
                        cur = e0
                    if cur < i:
                        segs.append((cur, i))
                    spans.extend(segs)
                    token_open = None
                elif nested_start is not None:
                    token_open[1].append((nested_start, i))
                    nested_start = None
            elif token_open:
                # Лишняя `}` на нулевом уровне: блок токенов считаем испорченным.
                token_open = None
            buf = ""
        elif c == ";":
            buf = ""  # конец декларации, селектор не продолжается
        else:
            buf += c
        i += 1
    # Незакрытый блок токенов (token_open != None) намеренно НЕ эмитим.
    return spans


def line_offsets(text):
    """Смещение начала каждой строки (index 0 → строка 1)."""
    starts = [0]
    idx = text.find("\n")
    while idx != -1:
        starts.append(idx + 1)
        idx = text.find("\n", idx + 1)
    return starts


def in_token_span(offset, spans):
    return any(s0 <= offset < e0 for s0, e0 in spans)


def token_block_lines(text):
    """Номера строк (1-based), целиком лежащие внутри блока палитры.

    Производная от token_block_spans: строка в блоке токенов, если её
    содержимое принадлежит диапазону палитры. Внутри блока токенов литералы —
    это сами токены, а не «магические цвета» (§2). Вне блока
    (`.app-sidebar-overlay { background: rgb(0 0 0 / 0.5) }`) ничего не
    меняется — магический цвет по-прежнему ловится.
    """
    out = set()
    if not text:
        return out
    starts = line_offsets(text)
    for s0, e0 in token_block_spans(text):
        first = bisect_right(starts, s0) - 1
        last = bisect_right(starts, e0 - 1) - 1 if e0 > s0 else first
        for ln in range(first, last + 1):
            lo, hi = starts[ln], starts[ln + 1] - 1 if ln + 1 < len(starts) else len(text)
            if s0 <= lo and hi <= e0:
                out.add(ln + 1)
    return out


COMMENT_RE = re.compile(r"^\s*(//|\*|#|<!--|\"\"\"|''')")

violations = []
ui_files = set()
no_design_files = set()
design_files = set()
err_by_design = {}
try:
    added = open(added_path, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    added = []

# Группируем добавленные строки по файлу: контекст (блок токенов :root/.dark и
# продолжение объявления `const X =`) нужно знать по ОКРУЖАЮЩЕМУ коду файла,
# а added.tsv построчный.
added_by_file = {}
for entry in added:
    parts = entry.split("\t", 2)
    if len(parts) != 3:
        continue
    f, lno, code = parts
    try:
        lno = int(lno)
    except ValueError:
        continue
    added_by_file.setdefault(f, []).append((lno, code))
for f in added_by_file:
    added_by_file[f].sort()

for f in sorted(added_by_file):
    ui_files.add(f)
    allowed_colors, allowed_px, dpath = rules_for_file(f)
    if not dpath:
        # Ни одного DESIGN.md для файла — не проверяем (иначе ложные error'ы),
        # но явно отмечаем в JSON, НЕ как error-блокер.
        no_design_files.add(f)
        continue
    design_files.add(dpath)
    # Контекст файла считаем один раз на файл: строки блоков токенов и сами
    # строки файла (для multiline-контекста объявления компонента).
    snap = file_snapshot(f)
    snap_text = "\n".join(snap) if snap else ""
    token_lines = token_block_lines(snap_text) if snap else set()
    token_spans = token_block_spans(snap_text) if snap else []
    lstarts = line_offsets(snap_text) if snap else []
    file_errors = 0
    for lno, code in added_by_file[f]:
        if "design:ignore" in code:
            continue
        if COMMENT_RE.match(code):
            continue
        # Hex/rgba ВНУТРИ блока токенов (:root/.dark верхнего уровня) — это и
        # есть палитра, её определение (DESIGN.md §2). Вне блока — обычный
        # магический цвет. Проверка ПО ПОЗИЦИИ литерала, а не по номеру строки:
        # строка может начинаться в блоке токенов и содержать вложенный блок
        # (`.card { ... }` внутри `:root {}`) — такой литерал не легален.
        base = lstarts[lno - 1] if 0 < lno <= len(lstarts) else 0
        for rx in (HEX_RE, RGBA_RE):
            for m in rx.finditer(code):
                off = base + m.start()
                if in_token_span(off, token_spans):
                    continue
                if norm_color(m.group()) not in allowed_colors:
                    violations.append({"file": f, "line": lno, "severity": "error",
                                       "rule": "magic-color",
                                       "message": f"магический цвет {m.group()} — вынеси в токены DESIGN.md (§2)"})
                    file_errors += 1
        if BOX_RE.search(code):
            violations.append({"file": f, "line": lno, "severity": "error",
                               "rule": "box-shadow",
                               "message": "box-shadow запрещён DESIGN.md (§2/§5) — используй border/outline или spacing/тон фона; исключение только по явному запросу пользователя"})
            file_errors += 1
        for m in PX_RE.findall(code):
            if m not in allowed_px:
                violations.append({"file": f, "line": lno, "severity": "warn",
                                   "rule": "magic-px",
                                   "message": f"магический размер {m} — добавь токен в DESIGN.md (§2) или design:ignore"})
    if file_errors:
        err_by_design.setdefault(dpath, set()).add(f)

# design-not-updated — per-design-файл: нарушения есть, а ИМЕННО ЕГО DESIGN.md
# (сервисный/корневой) не тронут в этой пачке.
for dpath, files in sorted(err_by_design.items()):
    if os.path.realpath(dpath) in _touched:
        continue
    rel = os.path.relpath(dpath, ROOT)
    shown = ", ".join(sorted(files)[:5]) + ("…" if len(files) > 5 else "")
    violations.append({"file": rel, "line": 0, "severity": "error",
                       "rule": "design-not-updated",
                       "message": (f"есть design-нарушения в {shown}, а {rel} не обновлён — "
                                   "предложи человеку точные правки (токены/компоненты/журнал §6); "
                                   "правит только владелец, коммит после его approve")})

errors = [v for v in violations if v["severity"] == "error"]
passed = not errors
design_files_rel = sorted(os.path.relpath(p, ROOT) for p in design_files)
no_design_rel = sorted(no_design_files)
out = {"design_file": os.path.relpath(root_design, ROOT) if root_design
          else (design_files_rel[0] if design_files_rel else ""),
       "design_files": design_files_rel,
       "files_without_design": no_design_rel,
       "ui_files": sorted(ui_files),
       "design_touched": bool(_touched), "passed": passed,
       "violations": violations,
       "summary": ("design guard passed" if passed
                   else f"design guard: {len(errors)} errors") +
                  (f" in {len(ui_files)} UI files" if ui_files else " (no UI changes)") +
                  (f"; no DESIGN.md for {len(no_design_rel)} files (skipped)" if no_design_rel else "")}
if not root_design and not design_files:
    # Полностью нет ни одного DESIGN.md — старый контракт exit 2.
    out["error"] = "no_design_file"
    out["hint"] = "bash .opencode/scripts/design/init.sh"
    out["passed"] = False
open(out_path, "w", encoding="utf-8").write(json.dumps(out, ensure_ascii=False, indent=2))
PY

# stdout — только JSON; stderr — human summary
cat "$GUARD_JSON"
if [[ "$JSON_ONLY" -eq 0 ]]; then
  python3 -c 'import json,sys; j=json.load(open(sys.argv[1],encoding="utf-8")); print("summary: "+j["summary"], file=sys.stderr);
print("design files: "+", ".join(j.get("design_files") or ["-"]), file=sys.stderr)
if j.get("files_without_design"): print("no design for (skipped): "+", ".join(j["files_without_design"][:10]), file=sys.stderr)
for v in j["violations"]:
    print("  " + v["severity"] + " " + v["rule"] + " " + v["file"] + ":" + str(v["line"]) + " - " + v["message"], file=sys.stderr)' "$GUARD_JSON"
fi

if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1],encoding="utf-8"))["passed"] else 1)' "$GUARD_JSON"; then
  exit 0
elif python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1],encoding="utf-8")).get("error")=="no_design_file" else 1)' "$GUARD_JSON"; then
  # Ни одного DESIGN.md в репозитории — старый контракт exit 2.
  echo "design/guard: нет DESIGN.md — сначала: bash .opencode/scripts/design/init.sh" >&2
  exit 2
else
  echo "design/guard: есть error-нарушения — коммит только после явного approve человека" >&2
  exit 1
fi

