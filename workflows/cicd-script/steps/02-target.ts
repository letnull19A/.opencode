#!/usr/bin/env bun
// @ts-nocheck
// 02-target — целевое состояние: нормализует target из входа + считает gaps vs survey.
// Вход: {survey:{...}, input:{title,desc,target:{pipeline,registry,image,deploy,branch}}}
// pipeline: ci-gate | build-push | deploy | full. deploy: none | ssh | compose | kubectl.
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

const target = {
  pipeline,
  registry: raw.registry || survey.registry_hint || "ghcr.io",
  image: raw.image || "",
  deploy,
  branch: raw.branch || "main",
};
const needsBuild = pipeline === "build-push" || pipeline === "full"
const needsCi = pipeline === "ci-gate" || pipeline === "full"
const needsCompose = deploy === "compose" || deploy === "ssh"

const gaps: any[] = []
if (needsBuild && !survey.has_dockerfile)
  gaps.push({ id: "dockerfile", desc: "нет Dockerfile для build-push — скелет через @docker-pack", owner_agent: "docker-pack" })
if (needsCi && !survey.has_ci)
  gaps.push({ id: "ci-yaml", desc: "нет .github/workflows — триггерный yaml через @ci-runner", owner_agent: "ci-runner" })
if (needsCompose && !(survey.compose_files || []).length)
  gaps.push({ id: "compose", desc: `нет compose-файла для deploy=${deploy} — compose через @devops`, owner_agent: null })
if (!survey.testCmd && (pipeline === "ci-gate" || pipeline === "full"))
  gaps.push({ id: "tests", desc: "нет тестовой команды — стадия test станет skip; тесты через @unit-test", owner_agent: "unit-test" })
if (needsBuild && !target.image)
  gaps.push({ id: "image-name", desc: "не задано target.image — уточнить у пользователя (registry/image)", owner_agent: "user" })
if (deploy !== "none" && needsCompose)
  gaps.push({ id: "deploy-creds", desc: `доступ к ${deploy}-цели (host/key/kubeconfig) — только от пользователя`, owner_agent: "user" })
if (!survey.has_dockerfile && (pipeline === "full" || pipeline === "ci-gate") && Object.keys(survey.scripts || {}).length === 0 && survey.stack === "unknown")
  gaps.push({ id: "recon", desc: "стек не распознан — глубокая разведка через @recon", owner_agent: "recon" })

console.log(JSON.stringify({ target, gaps, _reads: 1 }))
