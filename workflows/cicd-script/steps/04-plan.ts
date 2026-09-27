#!/usr/bin/env bun
// @ts-nocheck
// 04-plan — ordered стадии пайплайна из survey+target+classify (детерминированно, без LLM).
// Каждая стадия: {id,title,cmd,verify,rollback}. Gaps → blocked (что закрыть до/вне скрипта).
// Вход: {survey:{...}, target:{target:{...}, gaps:[...]}, classify:{pipeline_type,...}}
// Выход: {stages, blocked, risks, _reads}

import { readFileSync } from "fs"
function arg(n: string) { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : undefined }
const p = arg("--input")
let data: any = {}
try { data = JSON.parse(readFileSync(p!, "utf-8")) } catch { }
const survey = data.survey || {}
const tRaw = data.target || {}
const target = tRaw.spec || tRaw.target || (tRaw.pipeline ? tRaw : {}) || data.spec || {}
const gaps: any[] = tRaw.gaps || data.gaps || []
const pipeline_type = data.classify?.pipeline_type || target.pipeline || "ci-gate"
const gapIds = new Set(gaps.map((g: any) => g.id))

const testCmd = survey.testCmd || 'echo "skip: no test command"'
const lintCmd = survey.lintCmd || 'echo "skip: no lint script"'
const image = target.image || "${REGISTRY:-ghcr.io}/${IMAGE_NAME:-app}:dev"
const deployDest = target.deploy || "none"
const orchestrator = target.orchestrator || "unknown"

// команда деплоя зависит от пары (orchestrator, deploy) — смешивать запрещено
function deployCmd() {
  if (deployDest === "kubectl") return "kubectl apply -f k8s/ && kubectl rollout status deploy/${IMAGE_NAME:?}"
  if (deployDest === "compose" && orchestrator === "swarm") return "docker stack deploy -c docker-compose.yml -c docker-compose.prod.yml ${STACK_NAME:?}"
  if (deployDest === "compose") return "docker compose pull && docker compose up -d"
  if (deployDest === "ssh") return 'ssh "${DEPLOY_HOST:?}" "cd ${DEPLOY_DIR:?} && ./deploy.sh"'
  return 'echo "skip: deploy=none"'
}
function deployVerify() {
  if (deployDest === "kubectl") return "rollout status + kubectl get pods"
  if (deployDest === "compose" && orchestrator === "swarm") return "docker stack services ${STACK_NAME:?}"
  if (deployDest === "compose") return "docker compose ps + healthcheck"
  if (deployDest === "ssh") return "healthcheck цели"
  return "—"
}

const STAGES: Record<string, any[]> = {
  "ci-gate": [
    { id: "lint", title: "Линт", cmd: lintCmd, verify: "exit 0", rollback: "— (read-only)" },
    { id: "test", title: "Тесты", cmd: testCmd, verify: "exit 0", rollback: "— (read-only)" },
  ],
  "build-push": [
    { id: "build", title: "Сборка образа", cmd: `docker build -t ${image} .`, verify: "docker images " + image, rollback: `docker rmi ${image} || true` },
    { id: "push", title: "Публикация в registry", cmd: `docker push ${image}`, verify: "digest в stdout", rollback: "удалить тег в registry (вручную)" },
  ],
  "deploy": [
    { id: "deploy", title: `Деплой (${orchestrator}/${deployDest})`, cmd: deployCmd(), verify: deployVerify(), rollback: "предыдущий релиз/образ (вручную)" },
  ],
  "full": [
    { id: "lint", title: "Линт", cmd: lintCmd, verify: "exit 0", rollback: "— (read-only)" },
    { id: "test", title: "Тесты", cmd: testCmd, verify: "exit 0", rollback: "— (read-only)" },
    { id: "build", title: "Сборка образа", cmd: `docker build -t ${image} .`, verify: "docker images " + image, rollback: `docker rmi ${image} || true` },
    { id: "push", title: "Публикация в registry", cmd: `docker push ${image}`, verify: "digest в stdout", rollback: "удалить тег в registry (вручную)" },
    { id: "deploy", title: `Деплой (${orchestrator}/${deployDest})`, cmd: deployCmd(), verify: deployVerify(), rollback: "предыдущий релиз/образ (вручную)" },
  ],
}

const stages = (STAGES[pipeline_type] || STAGES["ci-gate"]).map((s) => ({
  ...s,
  blocked_by: [
    ...(s.id === "build" && gapIds.has("dockerfile") ? ["dockerfile"] : []),
    ...(s.id === "test" && gapIds.has("tests") ? ["tests"] : []),
    ...((s.id === "push") && gapIds.has("image-name") ? ["image-name"] : []),
    ...(s.id === "deploy" && gapIds.has("compose") ? ["compose"] : []),
    ...(s.id === "deploy" && gapIds.has("manifests") ? ["manifests"] : []),
    ...(s.id === "deploy" && gapIds.has("orchestrator") ? ["orchestrator"] : []),
    ...(s.id === "deploy" && gapIds.has("deploy-creds") ? ["deploy-creds"] : []),
  ],
}))

const risks: string[] = []
if (gapIds.has("orchestrator")) risks.push("оркестратор неизвестен — деплой и сети только TODO до ответа пользователя")
if (gapIds.has("deploy-creds")) risks.push("нет доступов к цели — стадия deploy останется TODO до ответа пользователя")
if (gapIds.has("dockerfile")) risks.push("сборка без Dockerfile невозможна — сначала @docker-pack")
if (stages.some((s) => s.blocked_by.length)) risks.push("заблокированные стадии генерируются как TODO-заглушки, не как рабочий код")

console.log(JSON.stringify({ stages, blocked: gaps, risks, _reads: 1 }))
