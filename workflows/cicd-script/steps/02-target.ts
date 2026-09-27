#!/usr/bin/env bun
// @ts-nocheck
// 02-target — целевое состояние: нормализует target из входа + считает gaps vs survey.
// Вход: {survey:{...}, input:{title,desc,target:{pipeline,registry,image,deploy,branch,orchestrator}}}
// pipeline: ci-gate | build-push | deploy | full. deploy: none | ssh | compose | kubectl.
// orchestrator: docker | swarm | k8s (дефолт — survey hint/текст; kubectl только для k8s).
// Выход: JSON {target:{...normalized}, gaps:[{id,desc,owner_agent}], _reads}
// owner_agent: recon | docker-pack | ci-runner | user | null (null = закрывается этим workflow).

import { readFileSync } from "fs"
function arg(n: string) { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : undefined }
const p = arg("--input")
let data: any = {}
try { data = JSON.parse(readFileSync(p!, "utf-8")) } catch { }
const survey = data.survey || {}
const raw = data.input?.target || data.target || {}
const text = `${data.input?.title || ""} ${data.input?.desc || ""}`.toLowerCase()

const PIPELINES = ["ci-gate", "build-push", "deploy", "full"]
let pipeline = raw.pipeline || ""
if (!PIPELINES.includes(pipeline)) {
  if (/deploy|депло|ssh|kubectl/.test(text)) pipeline = "deploy"
  else if (/docker|образ|push|реестр|registry/.test(text)) pipeline = "build-push"
  else pipeline = "ci-gate"
}

const DEPLOYS = ["none", "ssh", "compose", "kubectl"]
let deploy = raw.deploy || (pipeline === "deploy" || pipeline === "full" ? "ssh" : "none")
if (!DEPLOYS.includes(deploy)) {
  console.log(JSON.stringify({ valid: false, error: `target.deploy must be one of ${DEPLOYS.join("|")}, got '${deploy}'`, _reads: 1 }))
  process.exit(1)
}

// orchestrator-first: без него деплой и сети не проектируем
const ORCH = ["docker", "swarm", "k8s"]
let orchestrator = raw.orchestrator || ""
if (!ORCH.includes(orchestrator)) {
  if (/k8s|kubernetes|кубер|helm/.test(text)) orchestrator = "k8s"
  else if (/(^|[\s("'])рой([\s)"',.\-]|$)|swarm/i.test(text)) orchestrator = "swarm"
  else if (/docker|compose|контейнер/.test(text)) orchestrator = survey.orchestrator_hint === "unknown" ? "docker" : survey.orchestrator_hint
  else orchestrator = survey.orchestrator_hint || "unknown"
}
if (!ORCH.includes(orchestrator)) orchestrator = "unknown"
if (deploy === "kubectl" && orchestrator !== "k8s") {
  console.log(JSON.stringify({ valid: false, error: "target.deploy=kubectl только для orchestrator=k8s", _reads: 1 }))
  process.exit(1)
}

const target = {
  pipeline,
  registry: raw.registry || survey.registry_hint || "ghcr.io",
  image: raw.image || "",
  deploy,
  branch: raw.branch || "main",
  orchestrator,
};
const needsBuild = pipeline === "build-push" || pipeline === "full"
const needsCi = pipeline === "ci-gate" || pipeline === "full"
const needsCompose = (deploy === "compose" || deploy === "ssh") && orchestrator !== "k8s"
const needsDeploy = deploy !== "none" && (pipeline === "deploy" || pipeline === "full")

const gaps: any[] = []
if (orchestrator === "unknown" && needsDeploy)
  gaps.push({ id: "orchestrator", desc: "оркестратор не определён (docker/swarm/k8s) — без него деплой и сети не проектируем, уточнить у пользователя", owner_agent: "user" })
if (needsBuild && !survey.has_dockerfile)
  gaps.push({ id: "dockerfile", desc: "нет Dockerfile для build-push — скелет через @docker-pack", owner_agent: "docker-pack" })
if (needsCi && !survey.has_ci)
  gaps.push({ id: "ci-yaml", desc: "нет .github/workflows — триггерный yaml через @ci-runner", owner_agent: "ci-runner" })
if (needsCompose && !(survey.compose_files || []).length)
  gaps.push({ id: "compose", desc: `нет compose-файла для deploy=${deploy} (${orchestrator}) — compose через @devops`, owner_agent: null })
if (needsDeploy && orchestrator === "k8s" && !(survey.k8s_files || []).length)
  gaps.push({ id: "manifests", desc: "нет k8s-манифестов (Deployment/Service/Ingress) — через @devops", owner_agent: null })
if (!survey.testCmd && (pipeline === "ci-gate" || pipeline === "full"))
  gaps.push({ id: "tests", desc: "нет тестовой команды — стадия test станет skip; тесты через @unit-test", owner_agent: "unit-test" })
if (needsBuild && !target.image)
  gaps.push({ id: "image-name", desc: "не задано target.image — уточнить у пользователя (registry/image)", owner_agent: "user" })
if (needsDeploy && needsCompose)
  gaps.push({ id: "deploy-creds", desc: `доступ к ${deploy}-цели (${orchestrator}: host/key${orchestrator === "k8s" ? "/kubeconfig" : ""}) — только от пользователя`, owner_agent: "user" })
if (needsDeploy && deploy === "kubectl")
  gaps.push({ id: "deploy-creds", desc: "kubeconfig/доступ к кластеру — только от пользователя", owner_agent: "user" })
if (!survey.has_dockerfile && (pipeline === "full" || pipeline === "ci-gate") && Object.keys(survey.scripts || {}).length === 0 && survey.stack === "unknown")
  gaps.push({ id: "recon", desc: "стек не распознан — глубокая разведка через @recon", owner_agent: "recon" })

console.log(JSON.stringify({ target, gaps, _reads: 1 }))
