#!/usr/bin/env bash
# run.sh — graphify: индексация файлов и быстрый поиск по ним и содержимому.
# Легковесная альтернатива ripgrep/glob с кешем, без падения на /root/.cache.
# Индекс хранится в /tmp/opencode/graphify/<project>/index.json + .graphify.hash
# Поиск — по индексу (file) и по содержимому (content) через rg с TMPDIR=/tmp/opencode.
#
# Использование (из корня репо):
#   bash .opencode/scripts/graphify/run.sh index [--root <path>] [--force]
#   bash .opencode/scripts/graphify/run.sh search --query <q> [--mode file|content|both] [--limit <n>] [--root <path>] [--json]
#   bash .opencode/scripts/graphify/run.sh status [--root <path>]
#
#   --mode file    только по именам файлов (быстро, по индексу)
#   --mode content только по содержимому (rg)
#   --mode both    оба (по умолчанию)
#   --limit  макс. результатов (по умолчанию 50)
#   --json   только JSON на stdout (по умолчанию JSON + human hint на stderr)
#
# Выход search: stdout — только JSON, stderr — human summary. Для ИИ — парсь stdout.

set -euo pipefail

# ---------- helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "graphify: нужен '$1' (не найден в PATH)" >&2; exit 1; }; }
need_cmd git
need_cmd python3

ROOT=""
FORCE=0
QUERY=""
MODE="both"
LIMIT=50
JSON_ONLY=0
CMD=""

usage() {
  echo "Usage:"
  echo "  graphify index [--root <path>] [--force]"
  echo "  graphify search --query <q> [--mode file|content|both] [--limit <n>] [--root <path>] [--json]"
  echo "  graphify status [--root <path>]"
}

# ---------- parse ----------
if [[ $# -eq 0 ]]; then usage >&2; exit 1; fi
# --help без команды
if [[ "$1" == "-h" || "$1" == "--help" ]]; then usage; exit 0; fi
CMD="$1"; shift
case "$CMD" in
  index|search|status) ;;
  *) echo "graphify: неизвестная команда '$CMD'" >&2; usage >&2; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:?--root требует путь}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --query|-q) QUERY="${2:?--query требует значение}"; shift 2 ;;
    --mode) MODE="${2:?--mode требует file|content|both}"; shift 2 ;;
    --limit) LIMIT="${2:?--limit требует число}"; shift 2 ;;
    --json) JSON_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "graphify: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

case "$MODE" in file|content|both) ;; *) echo "graphify: --mode только file|content|both" >&2; exit 1 ;; esac
[[ "$LIMIT" =~ ^[0-9]+$ ]] && [[ "$LIMIT" -ge 0 ]] || { echo "graphify: --limit только неотрицательное число" >&2; exit 1; }

if [[ -z "$ROOT" ]]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ROOT="$(git rev-parse --show-toplevel)"
  else
    ROOT="$(pwd)"
  fi
fi
# нормализуем ROOT без trailing slash
ROOT="${ROOT%/}"
[[ -d "$ROOT" ]] || { echo "graphify: --root '$ROOT' не директория" >&2; exit 1; }

# кеш в /tmp/opencode/graphify/<hash> — переживает рестарт, быстро, без /root/.cache проблем
PROJECT_HASH="$(printf '%s' "$ROOT" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:12])')"
CACHE_DIR="/tmp/opencode/graphify/$PROJECT_HASH"
INDEX_JSON="$CACHE_DIR/index.json"
HASH_FILE="$CACHE_DIR/.graphify.hash"
mkdir -p "$CACHE_DIR"

# ---------- ensure .gitignore/.dockerignore + git hook (индексы не должны попасть в git) ----------
ensure_ignores_and_hook() {
  # Работаем с основным репо, а не с сабмодулем .opencode:
  # если ROOT внутри сабмодуля, находим суперпроект.
  local main_root="$ROOT"
  local super
  super="$(git -C "$ROOT" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
  if [[ -n "$super" ]]; then main_root="$super"; fi
  # также пробуем git toplevel для main_root (на случай если ROOT уже суперпроект)
  if git -C "$main_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    main_root="$(git -C "$main_root" rev-parse --show-toplevel 2>/dev/null || echo "$main_root")"
  fi
  for target in "$main_root" "$ROOT"; do
    [[ -d "$target" ]] || continue
    # .gitignore
    local gi="$target/.gitignore"
    if [[ -f "$gi" ]]; then
      grep -q "^\.graphify/" "$gi" 2>/dev/null || echo ".graphify/" >> "$gi"
      grep -q "^\.tmp/" "$gi" 2>/dev/null || echo ".tmp/" >> "$gi"
      grep -q "^tmp/opencode/" "$gi" 2>/dev/null || echo "tmp/opencode/" >> "$gi"
      grep -q "^\.opencode/\.cache/" "$gi" 2>/dev/null || echo ".opencode/.cache/" >> "$gi"
      grep -q "^\.opencode/\.graphify/" "$gi" 2>/dev/null || echo ".opencode/.graphify/" >> "$gi"
    elif [[ -d "$target/.git" || -f "$target/.git" ]]; then
      # нет .gitignore но есть .git — создаём минимальный
      {
        echo "# graphify — индексы вне репо (/tmp/opencode), на случай in-repo кеша — игнор"
        echo ".graphify/"
        echo ".tmp/"
        echo "tmp/opencode/"
        echo ".opencode/.cache/"
        echo ".opencode/.graphify/"
      } > "$gi"
    fi
    # .dockerignore
    local di="$target/.dockerignore"
    if [[ -f "$di" ]]; then
      grep -q "\.graphify" "$di" 2>/dev/null || echo "**/.graphify" >> "$di"
      grep -q "tmp/opencode" "$di" 2>/dev/null || echo "**/tmp/opencode" >> "$di"
      grep -q "\.opencode/.cache" "$di" 2>/dev/null || echo "**/.opencode/.cache" >> "$di"
    fi
    # git hook — ставится только в основном репо (где .git — директория, не файл сабмодуля)
    local git_dir
    git_dir="$(git -C "$target" rev-parse --absolute-git-dir 2>/dev/null || git -C "$target" rev-parse --git-dir 2>/dev/null || true)"
    # если git_dir относительный — делаем абсолютным относительно target
    if [[ "$git_dir" == ".git" || "$git_dir" == ".git/"* ]]; then
      git_dir="$target/$git_dir"
    elif [[ "$git_dir" != /* ]]; then
      git_dir="$target/$git_dir"
    fi
    # для сабмодуля git_dir — файл, для основного — директория
    if [[ -d "$git_dir" && -d "$git_dir/hooks" ]]; then
      local hook="$git_dir/hooks/pre-commit"
      local marker="# graphify — не пускает индексы в git"
      if ! grep -q "graphify" "$hook" 2>/dev/null; then
        # создаём или дописываем, не затирая существующий hook
        if [[ ! -f "$hook" ]]; then
          cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
# graphify — не пускает индексы в git
set -e
# если в индексе есть .graphify/tmp — снимаем и требуем игнор
if git diff --cached --name-only | grep -qE '(^\.graphify/|/\.graphify/|^\.tmp/|/\.tmp/|tmp/opencode|\.opencode/\.cache)'; then
  echo "graphify: индексы (.graphify/, .tmp/, tmp/opencode, .opencode/.cache) не должны попасть в git — снимаю с индекса" >&2
  git reset HEAD -- .graphify/ ".tmp/" tmp/opencode/ .opencode/.cache/ .opencode/.graphify/ 2>/dev/null || true
  echo "graphify: добавь эти пути в .gitignore/.dockerignore (уже сделано автоматически)" >&2
  exit 1
fi
HOOK
          chmod +x "$hook"
        else
          # дописываем в существующий hook, если там нет маркера
          if ! grep -q "$marker" "$hook" 2>/dev/null; then
            cat >> "$hook" <<'HOOK'

# graphify — не пускает индексы в git
if git diff --cached --name-only | grep -qE '(^\.graphify/|/\.graphify/|^\.tmp/|/\.tmp/|tmp/opencode|\.opencode/\.cache)'; then
  echo "graphify: индексы (.graphify/, .tmp/, tmp/opencode, .opencode/.cache) не должны попасть в git — снимаю с индекса" >&2
  git reset HEAD -- .graphify/ ".tmp/" tmp/opencode/ .opencode/.cache/ .opencode/.graphify/ 2>/dev/null || true
  exit 1
fi
HOOK
          fi
        fi
      fi
    fi
  done
}

# ---------- index ----------
do_index() {
  ensure_ignores_and_hook
  local git_head
  git_head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "no-git")"
  local status_hash
  status_hash="$(git -C "$ROOT" status --porcelain 2>/dev/null | head -n 100 | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:8])' 2>/dev/null || echo "no-status")"
  local cur_hash="${git_head}-${status_hash}"

  if [[ $FORCE -eq 0 && -f "$INDEX_JSON" && -f "$HASH_FILE" ]] && [[ "$(cat "$HASH_FILE" 2>/dev/null)" == "$cur_hash" ]]; then
    local cnt
    cnt="$(python3 -c 'import json; print(len(json.load(open("'"$INDEX_JSON"'",encoding="utf-8")).get("files",[])))' 2>/dev/null || echo 0)"
    if [[ $JSON_ONLY -eq 0 ]]; then
      echo "graphify: index свежий ($cnt файлов, $PROJECT_HASH) — $INDEX_JSON" >&2
    fi
    cat "$INDEX_JSON"
    return 0
  fi

  # собираем файлы через git ls-files (уважает .gitignore) + untracked неигнорируемые
  local tmp_list
  tmp_list="$(mktemp)"
  trap 'rm -f "${tmp_list:-}"' RETURN
  (
    git -C "$ROOT" ls-files --cached --others --exclude-standard -z 2>/dev/null | tr '\0' '\n' || true
  ) > "$tmp_list"

  # фильтруем: только файлы, без .git/, без node_modules/.next/dist/out/build
  python3 - "$ROOT" "$tmp_list" "$INDEX_JSON" "$cur_hash" << 'PY'
import os, sys, json, pathlib, hashlib, time
root, list_path, out_path, cur_hash = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
skip_dirs = {'.git', 'node_modules', '.next', 'dist', 'out', 'build', '.turbo', '.parcel-cache', 'coverage', '.nyc_output', 'tmp'}
skip_ext = {'.png','.jpg','.jpeg','.gif','.webp','.ico','.woff','.woff2','.ttf','.eot','.mp4','.mp3','.pdf','.zip','.tar','.gz','.jar','.class','.pyc','.o','.a'}
files=[]
for line in open(list_path, encoding='utf-8', errors='ignore'):
    p=line.strip()
    if not p: continue
    # пропуск по директориям
    parts=p.split('/')
    if any(part in skip_dirs for part in parts): continue
    # пропуск бинарей по расширению
    ext=os.path.splitext(p)[1].lower()
    if ext in skip_ext: continue
    abs_path=os.path.join(root,p)
    try:
        st=os.stat(abs_path)
        if not os.path.isfile(abs_path): continue
        size=st.st_size
        if size > 2_000_000: continue  # >2MB пропускаем (бинарь)
        mtime=int(st.st_mtime)
    except: continue
    files.append({"path": p, "size": size, "mtime": mtime})
files.sort(key=lambda x: x["path"])
out={
    "root": root,
    "hash": cur_hash,
    "indexed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "files": files,
    "count": len(files),
}
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path,'w',encoding='utf-8') as f: json.dump(out,f,ensure_ascii=False, indent=2)
print(json.dumps(out, ensure_ascii=False))
PY
  echo "$cur_hash" > "$HASH_FILE"
  if [[ $JSON_ONLY -eq 0 ]]; then
    local cnt2
    cnt2="$(python3 -c 'import json; print(json.load(open("'"$INDEX_JSON"'",encoding="utf-8"))["count"]' 2>/dev/null || echo 0)"
    echo "graphify: проиндексировано $cnt2 файлов → $INDEX_JSON" >&2
  fi
  cat "$INDEX_JSON"
}

# ---------- search ----------
do_search() {
  ensure_ignores_and_hook
  [[ -n "$QUERY" ]] || { echo "graphify: укажи --query" >&2; usage >&2; exit 1; }
  # убеждаемся что индекс есть (авто-индекс если нет)
  if [[ ! -f "$INDEX_JSON" ]]; then
    FORCE=0
    # тихо индексируем без вывода
    JSON_ONLY=1 do_index >/dev/null
  fi

  # готовим rg с правильным TMPDIR/XDG_CACHE_HOME чтобы не падать на /root/.cache
  export TMPDIR="/tmp/opencode"
  export XDG_CACHE_HOME="/tmp/opencode"
  export HOME="/tmp/opencode"
  mkdir -p "$TMPDIR" "$XDG_CACHE_HOME"

  python3 - "$ROOT" "$INDEX_JSON" "$QUERY" "$MODE" "$LIMIT" << 'PY'
import json, os, sys, re, subprocess, pathlib, fnmatch, time

root, index_path, query, mode, limit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
idx=json.load(open(index_path, encoding='utf-8'))
files=[f["path"] for f in idx.get("files",[])]

def file_search(q, files, limit):
    ql=q.lower()
    ql_norm=q.lower().replace("-", "").replace("_", "")
    is_glob = any(ch in q for ch in "*?[]")
    res=[]
    for p in files:
        pl=p.lower()
        pl_norm=pl.replace("-", "").replace("_", "")
        m=False
        if is_glob:
            if fnmatch.fnmatch(pl, ql) or fnmatch.fnmatch(os.path.basename(pl), ql):
                m=True
        else:
            if ql in pl or ql_norm in pl_norm:
                m=True
        if m:
            score=0
            if os.path.basename(pl)==ql: score=3
            elif ql in os.path.basename(pl) or ql_norm in os.path.basename(pl).replace("-", "").replace("_", ""): score=2
            elif ql in pl or ql_norm in pl_norm: score=1
            res.append({"path": p, "score": score})
    res.sort(key=lambda x: (-x["score"], x["path"]))
    return res[:limit] if limit>0 else res

def content_search(q, root, files, limit):
    # используем rg --json если есть, иначе grep
    rg_bin = None
    for cand in ["/root/.cache/opencode/bin/ripgrep-*", "/usr/bin/rg", "/usr/local/bin/rg"]:
        import glob
        for g in glob.glob(cand):
            if os.path.isfile(g) and os.access(g, os.X_OK):
                rg_bin=g; break
        if rg_bin: break
    if not rg_bin:
        # пробуем which rg
        import shutil
        rg_bin = shutil.which("rg")
    results=[]
    if rg_bin and os.path.isfile(rg_bin):
        # rg --json --no-config --hidden не нужен — индекс уже фильтрует
        cmd=[rg_bin, "--json", "--no-config", "--line-number", "--column", "--smart-case", "--hidden", "--glob", "!.git/*", "--glob", "!node_modules/*", "--glob", "!.next/*", "-e", q, root]
        env=dict(os.environ)
        env["TMPDIR"]="/tmp/opencode"
        env["XDG_CACHE_HOME"]="/tmp/opencode"
        try:
            proc=subprocess.run(cmd, capture_output=True, text=True, timeout=15, env=env)
            for line in proc.stdout.splitlines():
                if not line.strip(): continue
                try:
                    j=json.loads(line)
                except: continue
                if j.get("type")!="match": continue
                data=j.get("data",{})
                path=data.get("path",{}).get("text","")
                # делаем путь относительным
                if path.startswith(root):
                    path=os.path.relpath(path, root)
                # rg в json даёт lines, submatches
                line_no=data.get("line_number",0)
                col=data.get("column",0)
                # текст строки
                txt=""
                # в --json lines.text есть сырой текст
                lines_data=data.get("lines",{})
                if isinstance(lines_data, dict):
                    txt=lines_data.get("text","").strip()
                if not txt:
                    # fallback: submatches
                    subs=data.get("submatches",[])
                    if subs:
                        txt=subs[0].get("match",{}).get("text","")
                results.append({"path": path, "line": line_no, "column": col, "text": txt[:500], "score": 1})
                if limit>0 and len(results)>=limit: break
        except Exception as e:
            # fallback to grep
            rg_bin=None
    if not rg_bin or not results:
        # fallback: grep -rn
        if not results:
            try:
                cmd2=["grep", "-rn", "--include=*.ts", "--include=*.tsx", "--include=*.js", "--include=*.jsx", "--include=*.py", "--include=*.md", "--include=*.json", "-n", q, root]
                # но grep без фильтров — делаем просто grep -R
                cmd2=["grep", "-RIn", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.next", "-n", q, root]
                proc2=subprocess.run(cmd2, capture_output=True, text=True, timeout=15)
                for line in proc2.stdout.splitlines()[:limit if limit>0 else 1000]:
                    # format: path:line:content
                    parts=line.split(":",2)
                    if len(parts)<3: continue
                    p, l, txt = parts[0], parts[1], parts[2]
                    if p.startswith(root):
                        p=os.path.relpath(p, root)
                    try: ln=int(l)
                    except: ln=0
                    results.append({"path": p, "line": ln, "column": 0, "text": txt.strip()[:500], "score": 1})
                    if limit>0 and len(results)>=limit: break
            except: pass
    # дедуп и сортировка
    seen=set()
    uniq=[]
    for r in results:
        key=(r["path"], r["line"], r["text"][:80])
        if key not in seen:
            seen.add(key); uniq.append(r)
    uniq.sort(key=lambda x: (x["path"], x["line"]))
    return uniq[:limit] if limit>0 else uniq

file_results=[]
content_results=[]
if mode in ("file","both"):
    file_results=file_search(query, files, limit if mode=="file" else limit)
if mode in ("content","both"):
    # для both делим лимит поровну
    climit=limit//2 if mode=="both" and limit>0 else limit
    content_results=content_search(query, root, files, climit if mode=="both" else limit)

out={
    "query": query,
    "mode": mode,
    "root": root,
    "limit": limit,
    "file_results": file_results,
    "content_results": content_results,
    "totals": {
        "file_matched": len(file_results),
        "content_matched": len(content_results),
        "total": len(file_results)+len(content_results)
    },
    "hint": "file_results — по имени файла (индекс), content_results — по содержимому (rg/grep). Для ИИ: file_results[].path — открой read, content_results[].path:line — точное место."
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
}

# ---------- status ----------
do_status() {
  if [[ -f "$INDEX_JSON" ]]; then
    cat "$INDEX_JSON" | python3 -c 'import json,sys,os; d=json.load(sys.stdin); print(f"root: {d[\"root\"]}\ncount: {d[\"count\"]}\nindexed_at: {d.get(\"indexed_at\")}\nhash: {d.get(\"hash\")}\npath: \"'$INDEX_JSON'\"")'
  else
    echo "graphify: индекс не создан — запусти: bash .opencode/scripts/graphify/run.sh index --root $ROOT"
    exit 1
  fi
}

case "$CMD" in
  index) do_index ;;
  search)
    JSON_OUT="$(do_search)"
    echo "$JSON_OUT"
    if [[ $JSON_ONLY -eq 0 ]]; then
      python3 -c 'import json,sys; j=json.loads(sys.argv[1]); print(f"summary: query=\"{j[\"query\"]}\" mode={j[\"mode\"]} file:{j[\"totals\"][\"file_matched\"]} content:{j[\"totals\"][\"content_matched\"]} total:{j[\"totals\"][\"total\"]}", file=sys.stderr)' "$JSON_OUT" 2>/dev/null || true
    fi
    ;;
  status) do_status ;;
esac
