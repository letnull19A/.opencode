#!/usr/bin/env bun
// @ts-nocheck
// workflows/engine.ts — минимальный движок workflow'ов
// Запуск: bun workflows/engine.ts --workflow new-task --input '{"title":"...","desc":"..."}' [--dry-run] [--json]
// Guardrails (исполняемые, fail-closed): валидация схемы workflow (поля/верхние ключи, needs-порядок),
// containment step.run строго внутри workflows/, deny-паттерны против run-пути И содержимого файла шага,
// бюджеты max_reads/max_writes/max_cards (до и после шага), max_steps/require_BOARD(.devbox) до старта,
// dry-run hard-skip шагов с guardrails.mutates=true. Безопасность мутаций незадекларированных шагов —
// на скриптах (обязаны чтить --dry-run).

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

// guardrail: имя workflow — только безопасный slug, без путей
if (!/^[a-z0-9][a-z0-9-]{0,40}$/.test(workflowName)) { console.error(`guardrail: invalid workflow name '${workflowName}' (allowed: [a-z0-9-], ≤41 chars)`); process.exit(2) }

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

// guardrail: схема workflow — только известные поля, needs ссылаются на шаги выше
{
  const ids = new Set<string>()
  const allowedStepKeys = new Set(["id","run","needs","guardrails","description"])
  const allowedGuardKeys = new Set(["allow_tools","deny","max_reads","max_writes","max_cards","mutates"])
  for (const [i, s] of steps.entries()) {
    if (typeof s?.id !== "string" || typeof s?.run !== "string" || !s.id || !s.run) { console.error(`guardrail: step #${i} без id/run — стоп`); process.exit(2) }
    if (ids.has(s.id)) { console.error(`guardrail: duplicate step id '${s.id}' — стоп`); process.exit(2) }
    ids.add(s.id)
    for (const k of Object.keys(s)) if (!allowedStepKeys.has(k)) { console.error(`guardrail: step '${s.id}' неизвестное поле '${k}' — стоп`); process.exit(2) }
    for (const dep of (s.needs || [])) if (!ids.has(dep)) { console.error(`guardrail: step '${s.id}' needs неизвестный/поздний шаг '${dep}' — стоп`); process.exit(2) }
    for (const k of Object.keys(s.guardrails || {})) if (!allowedGuardKeys.has(k)) { console.error(`guardrail: step '${s.id}' неизвестный guardrail '${k}' — стоп`); process.exit(2) }
    // guardrail: канонический путь шага — строго внутри workflows/
    const canon = path.resolve(root, s.run)
    const wfRoot = path.join(root, "workflows") + path.sep
    if (!canon.startsWith(wfRoot)) { console.error(`guardrail: step '${s.id}' run выходит за workflows/ (${s.run}) — стоп`); process.exit(2) }
  }
  // guardrail: глобальные лимиты из guardrails.json — до запуска
  if (globalGuard.max_steps !== undefined && steps.length > globalGuard.max_steps) { console.error(`guardrail: steps ${steps.length} > max_steps ${globalGuard.max_steps} — стоп`); process.exit(2) }
  if (globalGuard.require_BOARD) {
    const devbox = path.join(root, ".devbox")
    if (!existsSync(devbox)) { console.error(`guardrail: require_BOARD — нет ${devbox} (сначала task-manager/init.sh) — стоп`); process.exit(2) }
  }
}

const runDir = path.join(root, ".workflows/run", runId)
mkdirSync(runDir, {recursive:true})

const denyPatterns: string[] = globalGuard.deny || ["git push --force","rm -rf","dokploy.*"]
let totalWrites = 0
let totalReads = 0
let createdCards = 0
const audit: any[] = []

// сколько карточек создал шаг: явное поле cards[]/createdCards/cardsCreated, иначе 0
function countCards(parsed: any): number {
  if (!parsed || typeof parsed !== "object") return 0
  if (Array.isArray(parsed.cards)) return parsed.cards.length
  for (const k of ["createdCards","cardsCreated","cards_created"]) {
    const v = parsed[k]
    if (typeof v === "number") return v
    if (Array.isArray(v)) return v.length
  }
  return 0
}

function matchDeny(patterns: string[], haystacks: string[]): string | null {
  for (const p of patterns) for (const h of haystacks) if (h.includes(p)) return p
  return null
}

function failClosed(stepId: string, reason: string, ms = 0): never {
  audit.push({ step: stepId, ok:false, ms, error: reason, dryRun, guardrail: true })
  writeFileSync(path.join(runDir,"audit.json"), JSON.stringify({ runId, workflow: workflowName, dryRun, steps: audit, prevOutputs },null,2))
  console.error(reason)
  process.exit(1)
}

function checkGuardrails(step:any, prevOutputs:any){
  const g = step.guardrails || {}
  const deny: string[] = [...(g.deny || [])]
  const stepPath = path.resolve(root, step.run)
  let content = ""
  try { content = readFileSync(stepPath, "utf-8") } catch {}
  // deny: локальный (шаг) + глобальный — против run-пути И содержимого файла шага
  const hit = matchDeny(deny, [step.run, content]) || matchDeny(denyPatterns, [step.run, content])
  if (hit) failClosed(step.id, `guardrail deny: шаг '${step.id}' содержит запрещённое '${hit}' — не запускаю`)
  // бюджет: до запуска (текущий шаг тоже не должен превышать)
  if (g.max_writes !== undefined && totalWrites >= g.max_writes) failClosed(step.id, `guardrail max_writes ${g.max_writes} уже исчерпан до шага ${step.id}`)
  if (g.max_reads !== undefined && totalReads >= g.max_reads) failClosed(step.id, `guardrail max_reads ${g.max_reads} уже исчерпан до шага ${step.id}`)
  if (g.max_cards !== undefined && createdCards >= g.max_cards) failClosed(step.id, `guardrail max_cards ${g.max_cards} уже исчерпан до шага ${step.id}`)
  return true
}

let prevOutputs: Record<string,any> = { input, _meta: { workflow: workflowName, runId, dryRun } }

for (const step of steps) {
  const stepPath = path.resolve(root, step.run)
  if (!existsSync(stepPath)) { console.error(`step file missing: ${step.run}`); process.exit(2) }
  checkGuardrails(step, prevOutputs)

  // preview gate: в dry-run шаги с declared-мутациями НЕ запускаются — только preview-запись
  if (dryRun && step.guardrails?.mutates === true) {
    audit.push({ step: step.id, ok:true, ms:0, skipped:"dry-run mutates", preview:true, dryRun })
    prevOutputs[step.id] = { preview: true, skipped: "dry-run: шаг с mutates=true не запускался" }
    continue
  }

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
  // бюджет учёта + fail-closed: превышение — стоп прогона, а не продолжение
  if (parsed._reads) totalReads += parsed._reads
  if (parsed._writes) totalWrites += parsed._writes
  const g = step.guardrails || {}
  if (g.max_writes !== undefined && totalWrites > g.max_writes) failClosed(step.id, `guardrail max_writes ${g.max_writes} превышен шагом ${step.id} (${totalWrites})`)
  if (g.max_reads !== undefined && totalReads > g.max_reads) failClosed(step.id, `guardrail max_reads ${g.max_reads} превышен шагом ${step.id} (${totalReads})`)
  const newCards = countCards(parsed)
  if (newCards) {
    createdCards += newCards
    const cap = g.max_cards ?? globalGuard.max_cards_per_run
    if (cap !== undefined && createdCards > cap) failClosed(step.id, `guardrail max_cards ${cap} превышен шагом ${step.id} (${createdCards})`)
  }

  audit.push({ step: step.id, ok:true, ms, out: parsed, dryRun })
  prevOutputs[step.id] = parsed
  // также мерджим top-level для удобства
  Object.assign(prevOutputs, parsed)
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
