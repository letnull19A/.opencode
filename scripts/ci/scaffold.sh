#!/usr/bin/env bash
# scaffold.sh — детерминированный скаффолд vendor-lock-free GitHub workflows.
# Копирует шаблоны scripts/ci/templates/*.yml → .github/workflows/*.yml без LLM-генерации.
# Не затирает существующие без --force, registry/image — через placeholders vars.DOCKER_*.
set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "$0")/templates" && pwd)"
DEST_DIR=".github/workflows"
TYPE="all"
FORCE=0
REGISTRY=""
IMAGE=""

usage() {
  echo "Usage: bash .opencode/scripts/ci/scaffold.sh --type <ci|docker|all> [--force] [--registry <host>] [--image <name>]"
  echo "  --type ci      → $DEST_DIR/ci.yml"
  echo "  --type docker  → $DEST_DIR/docker.yml (любой OCI-registry via vars.DOCKER_REGISTRY)"
  echo "  --type all     → оба (по умолчанию)"
  echo "  --registry     переопределить REGISTRY placeholder в docker.yml (default: ghcr.io via vars fallback)"
  echo "  --image        переопределить IMAGE (default: ghcr.io/\${{ github.repository }} via vars fallback)"
  echo "Примеры:"
  echo "  bash .opencode/scripts/ci/scaffold.sh --type ci"
  echo "  bash .opencode/scripts/ci/scaffold.sh --type docker --registry docker.io --image docker.io/user/repo"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) TYPE="${2:?--type требует ci|docker|all}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --registry) REGISTRY="${2:?}"; shift 2 ;;
    --image) IMAGE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "scaffold: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

case "$TYPE" in ci|docker|all) ;; *) echo "scaffold: --type должен быть ci|docker|all" >&2; exit 1 ;; esac

need_type() { [[ "$TYPE" == "$1" || "$TYPE" == "all" ]]; }

copy_one() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" && $FORCE -eq 0 ]]; then
    echo "scaffold: $dest уже существует — пропускаю (используй --force для перезаписи)" >&2
    return 0
  fi
  cp "$src" "$dest"
  # опциональная подмена registry/image если явно переданы (иначе оставляем vars-фолбэк шаблона)
  if [[ -n "$REGISTRY" ]]; then
    # меняем default 'ghcr.io' в fallback-цепочке на переданный registry
    sed -i "s#|| 'ghcr.io'#|| '$REGISTRY'#g" "$dest" 2>/dev/null || true
  fi
  if [[ -n "$IMAGE" ]]; then
    # IMAGE уже параметризуем — подсказка в комментарии, не хардкодим
    echo "scaffold: note: задай vars.DOCKER_IMAGE=$IMAGE в GitHub vars или передай inputs.image" >&2
  fi
  echo "scaffold: создан $dest"
}

if need_type ci; then
  copy_one "$TEMPLATE_DIR/ci.yml" "$DEST_DIR/ci.yml"
fi
if need_type docker; then
  copy_one "$TEMPLATE_DIR/docker.yml" "$DEST_DIR/docker.yml"
fi

echo ""
echo "Готово. Проверь:"
echo "  git status --short"
echo "  cat $DEST_DIR/*.yml | head -n 60"
echo "Для любого registry задай в GitHub → Settings → Secrets and variables → Actions:"
echo "  vars.DOCKER_REGISTRY (ghcr.io / docker.io / registry.example.com)"
echo "  vars.DOCKER_IMAGE (напр. docker.io/user/repo)"
echo "  secrets.REGISTRY_USERNAME / REGISTRY_PASSWORD (для GHCR достаточно GITHUB_TOKEN)"
