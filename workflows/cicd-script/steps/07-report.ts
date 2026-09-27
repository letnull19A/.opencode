#!/usr/bin/env bun
// @ts-nocheck
// 07-report — итоговая сводка для devops: скрипт, стадии, открытые gaps с
// владельцами-агентами, verify, следующие шаги. Read-only.
// Вход: всё prevOutputs {survey,target,classify,plan,scaffold,verify,input}
// Выход: {script,pipeline_type,stages,blocked,verify_ok,gaps_open,next,_reads}

import { readFileSync } from "fs"
function arg(n: string) { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : undefined }
const p = arg("--input")
let data: any = {}
try { data = JSON.parse(readFileSync(p!, "utf-8")) } catch { }

const scaffold = data.scaffold || {}
const verify = data.verify || {}
const classify = data.classify || {}
const plan = data.plan || {}
const tRaw = data.target || {}
const gaps: any[] = tRaw.gaps || data.gaps || []
const dryRun = !!data.dryRun

const gaps_open = gaps.map((g: any) => ({
  id: g.id, desc: g.desc,
  delegate: !g.owner_agent ? "закрывает @devops в этом workflow (compose/план)" : g.owner_agent === "user" ? "вопрос пользователю через question" : `task → @${g.owner_agent}`,
}))

const next: string[] = []
if (!(verify.ok ?? false)) next.push("почини verify-ошибки в скрипте (макс 3 цикла), затем повтор verify")
for (const g of gaps) {
  if (g.owner_agent && g.owner_agent !== "user") next.push(`закрыть gap ${g.id}: task → @${g.owner_agent}`)
  else if (g.owner_agent === "user") next.push(`закрыть gap ${g.id}: спросить пользователя (${g.desc})`)
}
if (verify.ok && !dryRun) next.push("коммит через /commit (атомарно, без секретов), пуш только через /push")
if (dryRun) next.push("dry-run preview — для реальных записей запусти без --dry-run")

console.log(JSON.stringify({
  script: scaffold.script || null,
  pipeline_type: classify.pipeline_type || null,
  stages: scaffold.stages || (plan.stages || []).map((s: any) => s.id),
  blocked: scaffold.blocked || [],
  verify_ok: verify.ok ?? false,
  verify_checks: verify.checks || [],
  gaps_open, next, dryRun, _reads: 1,
}))
