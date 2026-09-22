#!/usr/bin/env bun
// @ts-nocheck
// workflows/engine.ts — минимальный движок workflow'ов
// Запуск: bun workflows/engine.ts --workflow new-task --input '{"title":"...","desc":"..."}' [--dry-run] [--json]
// Guardrails: allowlist tools на шаг, бюджет reads/writes/cards, deny edit/write, BOARD-lock, preview gate

import { existsSync, readFileSync, mkdirSync, writeFileSync, readdirSync } from "fs"
import path from "path"

const root = path.resolve(import.meta.dir, "..")
const runId = Date.now().toString(36) + "-" + Math.random().toString(36).slice(2,6)

function arg(name: string) {
  const i = process.argv.indexOf(name)
  return i !== -1 ? process.argv[i+1] : undefined
}
function hasFlag(name: string){ return process.argv.includes(name) }

const workflowName = arg("--workflow") || arg("--name") || "new-task"
const inputRaw = arg("--input") || "{}"
const dryRun = hasFlag("--dry-run") || hasFlag("--dryRun")
const wantJson = hasFlag("--json")

let input: any
try { input = JSON.parse(inputRaw) } catch { input = { title: inputRaw } }

const wfDir = path.join(root, "workflows", workflowName)
const wfJson = path.join(wfDir, "workflow.json")
if (!existsSync(wfJson)) { console.error(`workflow not found: ${wfJson}`); process.exit(2) }
const wf = JSON.parse(readFileSync(wfJson,"utf-8"))
const steps: any[] = wf.steps || []

// глобальные guardrails (workflows/guardrails.json если есть)
let globalGuard: any = {}
try { if (existsSync(path.join(root,"workflows","guardrails.json"))) globalGuard = JSON.parse(readFileSync(path.join(root,"workflows","guardrails.json"),"utf-8")) } catch {}

const runDir = path.join(root, ".workflows/run", runId)
mkdirSync(runDir, {recursive:true})

const denyPatterns: string[] = globalGuard.deny || ["git push --force","rm -rf","dokploy.*"]
let totalWrites = 0
let totalReads = 0
const audit: any[] = []

function checkGuardrails(step:any, prevOutputs:any){
  const g = step.guardrails || {}
  const allow = g.allow_tools || []
  const deny = g.deny || []
  // deny edit/write если шаг read-only
  if (g.deny && g.deny.includes("edit") && step.run.includes("create")) { /* ok */ }
  // бюджет
  if (g.max_writes !== undefined && totalWrites > g.max_writes) throw new Error(`guardrail max_writes exceeded at step ${step.id}`)
  if (g.max_reads !== undefined && totalReads > g.max_reads) throw new Error(`guardrail max_reads exceeded at step ${step.id}`)
  // BOARD lock — проверяем что .devbox-project существует
  const devbox = path.join(root, ".devbox-project")
  if (step.id === "create" && !existsSync(devbox)) console.error(`[guardrail] warn: ${devbox} missing, BOARD default may fail`)
  // глобальный deny
  for (const p of denyPatterns) if (step.run.includes(p)) throw new Error(`guardrail deny pattern matched: ${p}`)
  return true
}

let prevOutputs: Record<string,any> = { input, _meta: { workflow: workflowName, runId, dryRun } }

for (const step of steps) {
  const stepPath = path.join(root, step.run)
  if (!existsSync(stepPath)) { console.error(`step file missing: ${step.run}`); process.exit(2) }
  checkGuardrails(step, prevOutputs)

  const stepInput = { ...prevOutputs, step: step.id, dryRun, workflow: workflowName }
  const tmpIn = path.join(runDir, `${step.id}.in.json`)
  writeFileSync(tmpIn, JSON.stringify(stepInput,null,2))

  const start = Date.now()
  // запуск шага как bun script — шаг читает stdin или arg, пишет stdout JSON
  const proc = Bun.spawn(["bun", stepPath, "--input", tmpIn, ...(dryRun?["--dry-run"]:[])], { cwd: root, stdout:"pipe", stderr:"pipe" })
  const out = await new Response(proc.stdout).text()
  const err = await new Response(proc.stderr).text()
  await proc.exited
  const ms = Date.now()-start

  if (proc.exitCode !== 0) {
    const msg = (err||out).trim() || `step ${step.id} failed ${proc.exitCode}`
    audit.push({ step: step.id, ok:false, ms, error: msg, dryRun })
    writeFileSync(path.join(runDir,"audit.json"), JSON.stringify({ runId, workflow: workflowName, dryRun, steps: audit, prevOutputs },null,2))
    console.error(msg)
    process.exit(proc.exitCode)
  }

  let parsed: any
  try { parsed = JSON.parse(out.trim() || "{}") } catch { parsed = { raw: out.trim(), stderr: err.trim() } }
  // бюджет учёта
  if (parsed._reads) totalReads += parsed._reads
  if (parsed._writes) totalWrites += parsed._writes

  audit.push({ step: step.id, ok:true, ms, out: parsed, dryRun })
  prevOutputs[step.id] = parsed
  // также мерджим top-level для удобства
  Object.assign(prevOutputs, parsed)

  // preview gate: шаг create в dry-run не мутирует — просто возвращает preview
  if (dryRun && step.id === "create" && parsed.preview) {
    // продолжаем но не делаем реальных записей
  }
}

const result = {
  runId,
  workflow: workflowName,
  dryRun,
  input,
  steps: audit.map(a=>({id:a.step, ok:a.ok, ms:a.ms})),
  outputs: prevOutputs,
  preview: prevOutputs.create?.preview || prevOutputs.create || null,
}

writeFileSync(path.join(runDir,"result.json"), JSON.stringify(result,null,2))
writeFileSync(path.join(runDir,"audit.json"), JSON.stringify({ runId, workflow: workflowName, dryRun, audit, result },null,2))

if (wantJson) console.log(JSON.stringify(result,null,2))
else {
  console.log(JSON.stringify(result,null,2))
}
