#!/usr/bin/env bash
# scaffold.sh — детерминированная генерация Dockerfile + .dockerignore по слоям
# Работает с @recon: stack определяется из фактов, но можно задать --stack явно.
# Не перезатирает без --force.
set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "$0")/templates" && pwd)"
STACK="auto"
APP=""
CONTEXT="."
DOCKERFILE="./Dockerfile"
FORCE=0

usage() {
  echo "Usage: bash .opencode/scripts/docker-pack/scaffold.sh --stack <node|python|go|auto> [--app <name>] [--context <path>] [--dockerfile <path>] [--force]"
  echo "  --stack node|python|go|auto  стек (auto → из package.json/pyproject.toml/go.mod)"
  echo "  --app <name>                 монорепо: приложение в apps/<name> (context/dockerfile подстроятся если не заданы)"
  echo "  --context <path>             build context (default . или apps/<app> если --app)"
  echo "  --dockerfile <path>          путь к Dockerfile (default ./Dockerfile или apps/<app>/Dockerfile)"
  echo "Примеры:"
  echo "  bash .opencode/scripts/docker-pack/scaffold.sh --stack node"
  echo "  bash .opencode/scripts/docker-pack/scaffold.sh --stack auto --app web"
  echo "  bash .opencode/scripts/docker-pack/scaffold.sh --stack python --context apps/api --dockerfile apps/api/Dockerfile --force"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack) STACK="${2:?}"; shift 2 ;;
    --app) APP="${2:?}"; shift 2 ;;
    --context) CONTEXT="${2:?}"; shift 2 ;;
    --dockerfile) DOCKERFILE="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "scaffold: неизвестный аргумент '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

case "$STACK" in node|python|go|auto) ;; *) echo "scaffold: --stack должен быть node|python|go|auto" >&2; exit 1 ;; esac

# auto-детект стека если auto
if [[ "$STACK" == "auto" ]]; then
  DETECT_CONTEXT="$CONTEXT"
  if [[ -n "$APP" && "$CONTEXT" == "." ]]; then
    # если монорепо и context не задан — детектим в apps/<app>
    if [[ -d "apps/$APP" ]]; then DETECT_CONTEXT="apps/$APP"; fi
  fi
  if [[ -f "$DETECT_CONTEXT/package.json" ]] || [[ -f "package.json" && "$DETECT_CONTEXT" == "." ]]; then STACK="node"
  elif [[ -f "$DETECT_CONTEXT/pyproject.toml" ]] || [[ -f "$DETECT_CONTEXT/requirements.txt" ]]; then STACK="python"
  elif [[ -f "$DETECT_CONTEXT/go.mod" ]]; then STACK="go"
  else STACK="node"; echo "scaffold: не определил стек в $DETECT_CONTEXT — fallback node" >&2
  fi
  echo "scaffold: auto-детект → $STACK (context $DETECT_CONTEXT)" >&2
fi

# монорепо defaults
if [[ -n "$APP" ]]; then
  if [[ "$CONTEXT" == "." ]]; then CONTEXT="apps/$APP"; fi
  if [[ "$DOCKERFILE" == "./Dockerfile" ]]; then DOCKERFILE="apps/$APP/Dockerfile"; fi
fi

DOCKERIGNORE_DIR="$(dirname "$DOCKERFILE")"
[[ "$DOCKERIGNORE_DIR" == "." ]] && DOCKERIGNORE_DIR="."
DOCKERIGNORE_PATH="$DOCKERIGNORE_DIR/.dockerignore"

# проверка существования без --force
if [[ -f "$DOCKERFILE" && $FORCE -eq 0 ]]; then
  echo "scaffold: $DOCKERFILE уже существует — пропускаю (используй --force)" >&2
  exit 0
fi

# выбор шаблона
case "$STACK" in
  node) SRC="$TEMPLATE_DIR/Dockerfile.node" ;;
  python) SRC="$TEMPLATE_DIR/Dockerfile.python" ;;
  go) SRC="$TEMPLATE_DIR/Dockerfile.go" ;;
esac

mkdir -p "$(dirname "$DOCKERFILE")"
cp "$SRC" "$DOCKERFILE"
echo "scaffold: создан $DOCKERFILE (stack $STACK)"

# .dockerignore — мерджим базовый + стек-специфичный
BASE_IGNORE="$TEMPLATE_DIR/.dockerignore"
mkdir -p "$(dirname "$DOCKERIGNORE_PATH")"
if [[ -f "$DOCKERIGNORE_PATH" && $FORCE -eq 0 ]]; then
  echo "scaffold: $DOCKERIGNORE_PATH уже существует — мерджим недостающие строки" >&2
  # добавляем только отсутствующие
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    grep -qxF "$line" "$DOCKERIGNORE_PATH" 2>/dev/null || echo "$line" >> "$DOCKERIGNORE_PATH"
  done < "$BASE_IGNORE"
else
  cp "$BASE_IGNORE" "$DOCKERIGNORE_PATH"
  echo "scaffold: создан $DOCKERIGNORE_PATH"
fi

# монорепо: добавить apps/<other>/** чтобы не тащить другие apps в контекст
if [[ -n "$APP" && -d "apps" ]]; then
  for d in apps/*; do
    [[ -d "$d" ]] || continue
    other="$(basename "$d")"
    [[ "$other" == "$APP" ]] && continue
    line="apps/$other/**"
    grep -qxF "$line" "$DOCKERIGNORE_PATH" 2>/dev/null || echo "$line" >> "$DOCKERIGNORE_PATH"
  done
  # если Dockerfile в apps/<app>, а контекст — apps/<app>, то apps/* уже вне контекста — но оставим для корневого контекста
fi

# стек-специфичные дополнения уже в базовом .dockerignore — для node/python/go достаточно
echo ""
echo "Готово:"
echo "  Dockerfile: $DOCKERFILE"
echo "  .dockerignore: $DOCKERIGNORE_PATH"
echo "  context: $CONTEXT"
echo "Проверка: cat $DOCKERFILE | head -30; cat $DOCKERIGNORE_PATH | head -20; docker build -t test:local -f $DOCKERFILE $CONTEXT 2>&1 | tail -5 || echo \"docker недоступен — skip\""
