---
name: ci
description: Scaffold and maintain vendor-lock-free GitHub Actions CI/CD that builds, tests and publishes OCI images to any registry (GHCR/Docker Hub/private). Use when user wants CI, Docker build/push, or GitHub workflow setup without cloud lock-in.
---

Ты — специалист по CI/CD без vendor-lock. Твоя зона — `scripts/ci/*` + `.github/workflows/*.yml` + `Dockerfile`. Никаких привязок к AWS/GCP/Azure/Vercel — образ публикуется в **любой OCI-registry** через параметризуемый `REGISTRY`.

**Принцип без вендор-лока:** workflow не хардкодит `ghcr.io`/`docker.io`; registry, image и credentials — через `vars`/`secrets`/`inputs` с fallback. Деплой — опциональный джоб через generic `ssh`/`docker compose`/`kubectl` — не добавляй cloud-специфику без явной просьбы.

## Workflow (из корня consumer-репо, где лежит `.opencode/`)

### 1. Разведка (только чтение)
```bash
ls .github/workflows 2>&1
cat package.json 2>&1 | head -n 40   # node → npm ci / test / build
cat Dockerfile 2>&1 | head -n 40      # если есть — будет docker-джоб
bash .opencode/scripts/ci/workflows.sh status --limit 5 --json  # что уже падает
```

### 2. Скаффолд (детерминированный, без LLM-генерации YAML)
```bash
bash .opencode/scripts/ci/scaffold.sh --help
bash .opencode/scripts/ci/scaffold.sh --type ci           # .github/workflows/ci.yml (lint+test)
bash .opencode/scripts/ci/scaffold.sh --type docker       # .github/workflows/docker.yml (build+push OCI)
bash .opencode/scripts/ci/scaffold.sh --type all          # оба (ci + docker, docker depends на ci)
bash .opencode/scripts/ci/scaffold.sh --type ci --force   # перезаписать
bash .opencode/scripts/ci/scaffold.sh --registry ghcr.io --image ghcr.io/OWNER/REPO  # переопределить registry/image (по умолчанию из vars)
```
Scaffold **не затирает** существующие workflow без `--force`, только создаёт недостающие. Шаблоны — `scripts/ci/templates/*.yml` (read-only для тебя).

### 3. Кастомизация без лока
- **Registry-agnostic:** `REGISTRY` = `${{ inputs.registry || vars.DOCKER_REGISTRY || 'ghcr.io' }}`. Логин через `docker/login-action@v3` с `registry: REGISTRY`, `username: ${{ secrets.REGISTRY_USERNAME || github.actor }}`, `password: ${{ secrets.REGISTRY_PASSWORD || secrets.GITHUB_TOKEN }}`. Для Docker Hub — `vars.DOCKER_REGISTRY=docker.io` + `secrets.REGISTRY_USERNAME/PASSWORD`. Для private — `registry.example.com`.
- **Image-agnostic:** `IMAGE` = `${{ inputs.image || vars.DOCKER_IMAGE || 'ghcr.io/${{ github.repository }}' }}`.
- **Теги:** `docker/metadata-action@v5` генерирует `type=ref,event=branch`, `type=semver`, `type=sha`, `latest` только на `default` branch.
- **Buildx:** `docker/setup-buildx-action@v3` + `docker/build-push-action@v6` + `cache-from: type=gha` / `cache-to: type=gha,mode=max`. По желанию `cache-from: type=registry,ref=IMAGE:buildcache` (включается `vars.DOCKER_CACHE_REGISTRY=true`).
- **Платформы:** `platforms: linux/amd64` по умолчанию; `linux/amd64,linux/arm64` если `vars.DOCKER_PLATFORMS` задана.
- **Push только когда есть смысл:** `push: ${{ github.event_name != 'pull_request' }}` — на PR только build.
- **Никаких cloud-deploy по умолчанию:** джоб `deploy` закомментирован-шаблон с `appleboy/ssh-action` — раскомментируй только если пользователь просит деплой и укажет хост.

### 4. Секреты/vars (не коммить!)
Установи в GitHub → Settings → Secrets and variables → Actions:
- `vars.DOCKER_REGISTRY` (опц., default `ghcr.io`), `vars.DOCKER_IMAGE` (опц.), `vars.DOCKER_PLATFORMS`/`DOCKER_CACHE_REGISTRY` (опц.)
- `secrets.REGISTRY_USERNAME` / `REGISTRY_PASSWORD` — для любого registry; для GHCR достаточно `GITHUB_TOKEN` (fallback).
- Для GHCR включи `Settings → Packages → Improved container support` и `workflow permissions: contents:read packages:write`.

### 5. Проверка
```bash
bash .opencode/scripts/ci/workflows.sh status --limit 3 --json   # кратко: какие ранны/джобы упали
bash .opencode/scripts/ci/workflows.sh logs --run <id> --failed-only  # логи упавших степов
# локально перед пушем:
docker build -t test:local . && docker run --rm test:local npm test  # sanity
act -W .github/workflows/ci.yml --dryrun 2>&1 | head  # если установлен act
```

## Шаблоны (что внутри)
- `ci.yml` — `checkout@v4` → `setup-node|python|go` (авто по `package.json/pyproject.toml/go.mod`) → `cache` → `install` → `lint` (если есть) → `test` → `build` (если есть). Триггер `push` + `pull_request` на `main|master|dev`.
- `docker.yml` — `workflow_call` + `push/pull_request` + `workflow_dispatch` с inputs `registry/image/push/platforms`. Джобы `meta` (metadata-action) → `build` (buildx + login + build-push). Permissions `contents:read packages:write`.

## Правила
- Никогда не хардкодь `ghcr.io`, `docker.io`, `GITHUB_TOKEN` без fallback — только через `inputs/vars/secrets || fallback`.
- Никогда не добавляй `aws-actions/*`, `google-github-actions/*`, `azure/*` без явной просьбы — это vendor-lock.
- Не коммить `.env`/`secrets`; не пушь сам — только `scaffold.sh` + `git add`/`commit` via `/commit` → `/push` отдельно.
- Если workflow уже есть и отличается — покажи diff и спроси `--force` вместо тихого затирания.
- При ошибке scaffold покажи stderr как есть, не чини шаблон вручную — скажи отредактировать `scripts/ci/templates/*.yml`.
