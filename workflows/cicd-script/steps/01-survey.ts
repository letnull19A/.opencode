#!/usr/bin/env bun
// @ts-nocheck
// 01-survey — actual state: что уже есть в репо для CI/CD (read-only).
// Разведка через fs + git remote, без LLM. Значения .env НЕ читаем — только имена файлов.
// В compose-файлах ищем только структурные ключи (deploy:/kind:), значения не храним.
// Вход: --input <path> с {input:{title,desc}}
// Выход: JSON {stack,pkgMgr,scripts,testCmd,has_dockerfile,compose_files,k8s_files,has_stack_file,orchestrator_hint,has_ci,workflows,env_files,cicd_scripts,registry_hint,_reads}

import { readFileSync, existsSync, readdirSync } from "fs"
import path from "path"
function arg(n: string) { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : undefined }
const p = arg("--input")
let data: any = {}
try { data = p ? JSON.parse(readFileSync(p, "utf-8")) : {} } catch { }
const root = process.cwd()
let reads = 0
const exists = (f: string) => { reads++; return existsSync(path.join(root, f)) }
const read = (f: string) => { reads++; try { return readFileSync(path.join(root, f), "utf-8") } catch { return "" } }
const ls = (d: string) => { reads++; try { return readdirSync(path.join(root, d)) } catch { return [] } }

// стек и пакетный менеджер
let stack = "unknown", pkgMgr = ""
const pkgRaw = read("package.json")
let scripts: Record<string, string> = {}
if (pkgRaw) {
  stack = "node"
  try { scripts = JSON.parse(pkgRaw).scripts || {} } catch { }
  if (exists("pnpm-lock.yaml")) pkgMgr = "pnpm"
  else if (exists("bun.lockb") || exists("bun.lock")) pkgMgr = "bun"
  else if (exists("yarn.lock")) pkgMgr = "yarn"
  else pkgMgr = "npm"
} else if (exists("pyproject.toml") || exists("requirements.txt")) stack = "python"
else if (exists("go.mod")) stack = "go"
else if (exists("Cargo.toml")) stack = "rust"

const testCmd = scripts.test ? `${pkgMgr || "npm"} test` : (stack === "python" ? "pytest" : stack === "go" ? "go test ./..." : stack === "rust" ? "cargo test" : "")
const lintCmd = scripts.lint ? `${pkgMgr || "npm"} run lint` : ""

// docker / compose / swarm / k8s (имена + структурные ключи — без секретов)
const topFiles = ls(".")
const has_dockerfile = topFiles.some((f) => /^Dockerfile/i.test(f))
const compose_files = topFiles.filter((f) => /docker-compose.*\.ya?ml$|^compose.*\.ya?ml$/i.test(f))
const has_stack_file = topFiles.some((f) => /docker-stack.*\.ya?ml$/i.test(f))
const k8s_files = [...ls("k8s"), ...ls("manifests"), ...ls("helm")]
  .filter((f) => /\.ya?ml$/.test(f) || /chart\.ya?ml$/i.test(f))
const env_files = topFiles.filter((f) => /^\.env(\..+)?$/.test(f))
const cicd_scripts = ls("scripts/cicd").filter((f) => f.endsWith(".sh"))

// orchestrator_hint: k8s-манифесты > swarm-признаки > compose > unknown
let orchestrator_hint = "unknown"
let orchestrator_evidence = ""
const hasK8sKind = [...ls("k8s"), ...ls("manifests")]
  .filter((f) => /\.ya?ml$/.test(f))
  .slice(0, 5)
  .some((f) => /^\s*kind:\s*(Deployment|StatefulSet|DaemonSet|Service|Ingress)/m.test(read(`k8s/${f}`) || read(`manifests/${f}`)))
let hasSwarmDeploy = has_stack_file
if (!hasSwarmDeploy) {
  for (const c of compose_files.slice(0, 3)) {
    const t = read(c)
    if (/^\s*deploy:\s*$/m.test(t) && /replicas|resources|restart_policy/.test(t)) { hasSwarmDeploy = true; break }
  }
}
if (k8s_files.length > 0 || hasK8sKind) { orchestrator_hint = "k8s"; orchestrator_evidence = `k8s-манифесты: ${k8s_files.slice(0, 3).join(",") || "kind: в k8s/manifests"}` }
else if (hasSwarmDeploy) { orchestrator_hint = "swarm"; orchestrator_evidence = "docker-stack файл или секция deploy: в compose" }
else if (compose_files.length > 0) { orchestrator_hint = "docker"; orchestrator_evidence = `compose: ${compose_files.slice(0, 2).join(",")}` }

// GHA workflows + registry hint
const workflows: string[] = ls(".github/workflows").filter((f) => /\.ya?ml$/.test(f))
let registry_hint = ""
for (const w of workflows.slice(0, 4)) {
  const c = read(`.github/workflows/${w}`)
  const m = c.match(/(ghcr\.io|docker\.io|registry\.\S+)/)
  if (m) { registry_hint = m[1]; break }
}

// git remote (только владелец/репо для дефолтного image)
let remote = ""
try {
  const proc = Bun.spawnSync(["git", "remote", "get-url", "origin"], { cwd: root, stdout: "pipe", stderr: "pipe" })
  remote = (proc.stdout?.toString() || "").trim()
} catch { }

console.log(JSON.stringify({
  stack, pkgMgr, scripts, testCmd, lintCmd,
  has_dockerfile, compose_files, has_stack_file, k8s_files,
  orchestrator_hint, orchestrator_evidence,
  has_ci: workflows.length > 0, workflows,
  env_files, cicd_scripts, registry_hint, remote, _reads: reads,
}))
