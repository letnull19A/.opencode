#!/usr/bin/env bun
// @ts-nocheck
// 05-create — создаёт карточки в Trello (или preview в dry-run)
// Guardrails: max_writes 5, max_cards 3, BOARD из .devbox-project, только allow_tools
// Вход: {plan:{cards}, validate, ... , dryRun}
// Выход: {created:[{title,url}], preview:{cards}, _writes}

import { readFileSync, existsSync } from "fs"
import path from "path"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
const dryRun = process.argv.includes("--dry-run") || process.argv.includes("--dryRun")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const cards: any[] = data.plan?.cards || data.cards || []
const root = path.resolve(import.meta.dir, "../../..")

if (!cards.length) { console.log(JSON.stringify({ error:"no cards from plan", _writes:0 })); process.exit(1) }
if (cards.length > 5) { console.log(JSON.stringify({ error:`guardrail max_cards 5 exceeded: ${cards.length}`, _writes:0 })); process.exit(1) }

// dry-run — preview без мутаций (как issue-writer preview)
if (dryRun) {
  const preview = cards.map(c=>({ title:c.title, list: c.list||"Backlog", desc: (c.desc||"").slice(0,300) }))
  console.log(JSON.stringify({ preview: { cards: preview }, created: [], dryRun:true, message:`dry-run: ${preview.length} карточек, мутаций нет — запусти без --dry-run для создания`, _writes:0 }))
  process.exit(0)
}

// реальное создание — вызываем scripts/task-manager/create.sh
// BOARD берётся из .devbox-project автоматически
const created: any[] = []
for (const c of cards) {
  const title = c.title
  const desc = c.desc || ""
  const list = c.list || "Backlog"
  // защита от пустого title
  if (!title || title.length<3) continue
  const script = path.join(root, ".opencode/scripts/task-manager/create.sh")
  if (!existsSync(script)) { console.log(JSON.stringify({ error:`script missing ${script}`, _writes: created.length })); process.exit(1) }
  const proc = Bun.spawn(["bash", script, "--title", title, "--list", list, "--desc", desc], { cwd: root, stdout:"pipe", stderr:"pipe" })
  const out = await new Response(proc.stdout).text()
  const err = await new Response(proc.stderr).text()
  await proc.exited
  if (proc.exitCode !== 0) {
    console.log(JSON.stringify({ error: (out+"\n"+err).trim() || `create failed ${proc.exitCode}`, created, _writes: created.length }))
    process.exit(proc.exitCode)
  }
  // скрипт печатает URL или id
  const url = (out.match(/https:\/\/trello\.com\/c\/\S+/) || [out.trim().split("\n").pop()])[0]
  created.push({ title, list, url: url?.slice(0,120) })
  if (created.length >= 3) break // guardrail max_cards 3 для одного прогона
}

console.log(JSON.stringify({ created, preview:null, dryRun:false, _writes: created.length }))
