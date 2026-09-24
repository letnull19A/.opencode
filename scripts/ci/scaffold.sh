#!/usr/bin/env bash
# scaffold.sh — детерминированный скаффолд vendor-lock-free GitHub workflows.
# Копирует шаблоны scripts/ci/templates/*.yml → .github/workflows/*.yml без LLM-генерации.
# Поддерживает single и monorepo (apps/<app>), registry/image/context/dockerfile, не затирает без --force.
set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "$0")/templates" && pwd)"
DEST_DIR=".github/workflows"
TYPE="all"
FORCE=0
REGISTRY=""
IMAGE=""
MONOREPO=0
APP=""
APPS_DIR="apps"
CONTEXT=""
DOCKERFILE=""

usage() {
  echo "Usage: bash .opencode/scripts/ci/scaffold.sh --type <ci|docker|all> [--force] [--registry <host>] [--image <name>] [--monorepo] [--app <name|all>] [--apps-dir <dir>] [--context <path>] [--dockerfile <path>]"
  echo "  --type ci      → $DEST_DIR/ci.yml (single) или ci-<app>.yml (monorepo per app)"
  echo "  --type docker  → $DEST_DIR/docker.yml (single) или docker-<app>.yml (monorepo per app)"
  echo "  --type all     → оба (по умолчанию)"
  echo "  --monorepo     включить монорепо-режим с apps/<app> (default apps dir = apps)"
  echo "  --app <name>   имя приложения (папка в apps/); app=all → по workflow на каждую папку в apps/*"
  echo "  --apps-dir     директория монорепо (default apps)"
  echo "  --context      build context (default .: single, apps/<app> : monorepo)"
  echo "  --dockerfile   путь к Dockerfile (default ./Dockerfile, монорепо apps/<app>/Dockerfile)"
  echo "  --registry     переопределить REGISTRY fallback в docker.yml (default ghcr.io via vars)"
  echo "  --image        подсказка vars.DOCKER_IMAGE (не хардкодит, только hint)"
  echo "Примеры:"
  echo "  bash .opencode/scripts/ci/scaffold.sh --type ci"
  echo "  bash .opencode/scripts/ci/scaffold.sh --type docker --registry docker.io --image docker.io/user/repo"
  echo "  bash .opencode/scripts/ci/scaffold.sh --type all --monorepo --app web --apps-dir apps"
  echo "  bash .opencode/scripts/ci/scaffold.sh --type all --monorepo --app all --apps-dir apps"
  echo "  bash .opencode/scripts/ci/scaffold.sh --type docker --context apps/web --dockerfile apps/web/Dockerfile --image ghcr.io/OWNER/REPO/web"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) TYPE="${2:?--type требует ci|docker|all}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --registry) REGISTRY="${2:?}"; shift 2 ;;
    --image) IMAGE="${2:?}"; shift 2 ;;
    --monorepo) MONOREPO=1; shift ;;
    --app) APP="${2:?}"; shift 2 ;;
    --apps-dir) APPS_DIR="${2:?}"; shift 2 ;;
    --context) CONTEXT="${2:?}"; shift 2 ;;
    --dockerfile) DOCKERFILE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "scaffold: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

case "$TYPE" in ci|docker|all) ;; *) echo "scaffold: --type должен быть ci|docker|all" >&2; exit 1 ;; esac
if [[ $MONOREPO -eq 1 && -z "$APP" ]]; then
  echo "scaffold: --monorepo требует --app <name|all> (напр. --app web или --app all)" >&2; exit 1
fi
if [[ $MONOREPO -eq 0 && ( -n "$CONTEXT" || -n "$DOCKERFILE" ) ]]; then
  # allow single custom context/dockerfile without monorepo flag
  :
fi

need_type() { [[ "$TYPE" == "$1" || "$TYPE" == "all" ]]; }

# список приложений для monorepo app=all
list_apps() {
  local dir="$APPS_DIR"
  if [[ ! -d "$dir" ]]; then echo ""; return; fi
  for d in "$dir"/*; do [[ -d "$d" ]] || continue; basename "$d"; done | sort
}

patch_for_app() {
  local file="$1" app="$2" cxt="$3" dfile="$4"
  # name
  sed -i "s/^name: Docker$/name: Docker ($app)/" "$file" 2>/dev/null || true
  sed -i "s/^name: CI$/name: CI ($app)/" "$file" 2>/dev/null || true
  # paths filter — вставляем после каждого branches: [...] в on.push/pull_request
  if grep -q "branches:" "$file" && ! grep -q "paths:" "$file"; then
    python3 - "$file" "$app" "$APPS_DIR" << 'PY'
import pathlib, sys
p, app, apps_dir = sys.argv[1], sys.argv[2], sys.argv[3]
path = pathlib.Path(p)
lines = path.read_text().splitlines()
out = []
needle = f"{apps_dir}/{app}/**"
for i, line in enumerate(lines):
    out.append(line)
    if "branches:" in line and "[" in line and "]" in line:
        # если следующая непустая уже paths — пропускаем
        nxt = ""
        for j in range(i+1, min(i+4, len(lines))):
            if lines[j].strip():
                nxt = lines[j].strip()
                break
        if nxt.startswith("paths:") or needle in "\n".join(lines[max(0,i-2):i+4]):
            continue
        indent = line[:line.find("branches:")]
        out.append(f"{indent}paths:")
        out.append(f"{indent}  - '{needle}'")
path.write_text("\n".join(out) + "\n")
PY
  fi
  # context/dockerfile — через env fallback (template уже использует CONTEXT/DOCKERFILE env), но для монорепо
  # зафиксируем defaults чтобы без vars тоже работало: подменим fallback '.'/'./Dockerfile' на apps/<app>
  if [[ -n "$cxt" ]]; then
    # меняем default CONTEXT fallback
    sed -i "s#|| '.' }}#|| '$cxt' }}#g" "$file" 2>/dev/null || true
  elif [[ -n "$app" ]]; then
    sed -i "s#|| '.' }}#|| '$APPS_DIR/$app' }}#g" "$file" 2>/dev/null || true
  fi
  if [[ -n "$dfile" ]]; then
    sed -i "s#|| './Dockerfile' }}#|| '$dfile' }}#g" "$file" 2>/dev/null || true
  elif [[ -n "$app" ]]; then
    sed -i "s#|| './Dockerfile' }}#|| '$APPS_DIR/$app/Dockerfile' }}#g" "$file" 2>/dev/null || true
  fi
  # для ci.yml — working directory: подменим node job чтобы шел в app dir (если scaffold ci)
  if [[ "$file" == *"ci-"* ]]; then
    # добавим defaults.run.working-directory в node job (простой патч: вставим после runs-on)
    if ! grep -q "working-directory" "$file"; then
      python3 - "$file" "$APPS_DIR/$app" << 'PY2'
import pathlib, sys
p, wd = sys.argv[1], sys.argv[2]
t = pathlib.Path(p).read_text()
# вставим working-directory в job node (после runs-on)
t = t.replace("  node:\n    needs: detect\n    if: needs.detect.outputs.node == 'true'\n    runs-on: ubuntu-latest", f"  node:\n    needs: detect\n    if: needs.detect.outputs.node == 'true'\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: {wd}", 1)
pathlib.Path(p).write_text(t)
PY2
    fi
  fi
}

copy_one() {
  local src="$1" dest="$2" app="${3:-}"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" && $FORCE -eq 0 ]]; then
    echo "scaffold: $dest уже существует — пропускаю (используй --force для перезаписи)" >&2
    return 0
  fi
  cp "$src" "$dest"
  if [[ -n "$REGISTRY" ]]; then
    sed -i "s#|| 'ghcr.io'#|| '$REGISTRY'#g" "$dest" 2>/dev/null || true
  fi
  if [[ -n "$app" ]]; then
    local cxt="${CONTEXT:-$APPS_DIR/$app}"
    local dfile="${DOCKERFILE:-$APPS_DIR/$app/Dockerfile}"
    # если CONTEXT/DOCKERFILE явно не заданы — берём app-путь, иначе явно переданные
    if [[ -n "$CONTEXT" ]]; then cxt="$CONTEXT"; fi
    if [[ -n "$DOCKERFILE" ]]; then dfile="$DOCKERFILE"; fi
    patch_for_app "$dest" "$app" "$cxt" "$dfile"
  else
    # single с кастом context/dockerfile
    if [[ -n "$CONTEXT" ]]; then sed -i "s#|| '.' }}#|| '$CONTEXT' }}#g" "$dest" 2>/dev/null || true; fi
    if [[ -n "$DOCKERFILE" ]]; then sed -i "s#|| './Dockerfile' }}#|| '$DOCKERFILE' }}#g" "$dest" 2>/dev/null || true; fi
  fi
  if [[ -n "$IMAGE" ]]; then
    echo "scaffold: note: задай vars.DOCKER_IMAGE=$IMAGE в GitHub vars или передай inputs.image (шаблон оставлен generic)" >&2
  fi
  echo "scaffold: создан $dest"
}

# основной поток
if [[ $MONOREPO -eq 1 && "$APP" == "all" ]]; then
  APPS="$(list_apps)"
  if [[ -z "$APPS" ]]; then echo "scaffold: --monorepo --app all но в $APPS_DIR/ нет подпапок" >&2; exit 1; fi
  for app in $APPS; do
    if need_type ci; then
      copy_one "$TEMPLATE_DIR/ci.yml" "$DEST_DIR/ci-$app.yml" "$app"
    fi
    if need_type docker; then
      # IMAGE per app: если IMAGE задан как ghcr.io/owner/repo, добавим /<app> суффикс
      copy_one "$TEMPLATE_DIR/docker.yml" "$DEST_DIR/docker-$app.yml" "$app"
    fi
  done
elif [[ $MONOREPO -eq 1 ]]; then
  if need_type ci; then
    copy_one "$TEMPLATE_DIR/ci.yml" "$DEST_DIR/ci-$APP.yml" "$APP"
  fi
  if need_type docker; then
    copy_one "$TEMPLATE_DIR/docker.yml" "$DEST_DIR/docker-$APP.yml" "$APP"
  fi
else
  # single repo
  if need_type ci; then
    copy_one "$TEMPLATE_DIR/ci.yml" "$DEST_DIR/ci.yml"
  fi
  if need_type docker; then
    copy_one "$TEMPLATE_DIR/docker.yml" "$DEST_DIR/docker.yml"
  fi
fi

echo ""
echo "Готово. Проверь:"
echo "  git status --short"
echo "  cat $DEST_DIR/*.yml | head -n 80"
echo "Для любого registry задай в GitHub → Settings → Secrets and variables → Actions:"
echo "  vars.DOCKER_REGISTRY (ghcr.io / docker.io / registry.example.com)"
echo "  vars.DOCKER_IMAGE (напр. docker.io/user/repo или ghcr.io/owner/repo/<app> для монорепо)"
echo "  vars.DOCKER_CONTEXT / DOCKERFILE (опц., переопределяют context/dockerfile)"
echo "  secrets.REGISTRY_USERNAME / REGISTRY_PASSWORD (для GHCR достаточно GITHUB_TOKEN)"
if [[ $MONOREPO -eq 1 ]]; then
  echo "Монорепо: workflow'ы отфильтрованы по paths: $APPS_DIR/<app>/** и используют context $APPS_DIR/<app>"
fi
