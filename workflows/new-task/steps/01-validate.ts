#!/usr/bin/env bun
// @ts-nocheck
// 01-validate — проверяет что задачу можно брать в работу. Неполную — отклоняет.
// Вход: --input <path> с {input:{title,desc}} или {title,desc}
// Выход: JSON {title,desc,context,what,acceptance,valid,error,_reads}

import { readFileSync } from "fs"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = p? JSON.parse(readFileSync(p,"utf-8")) : {} } catch {}
const input = data.input || data
let title = (input.title || input.name || "").trim()
let desc = (input.desc || input.description || "").trim()

// поддержка raw строки: bun ... --input '{"title":"..."}' уже, но если передали просто строку — берём из prevOutputs.input
if (!title && typeof input === "string") title = input.trim()

// достаём из desc блоки по шаблону (если есть)
function extract(h:string, t:string){
  const re = new RegExp(`##\\s*${h}[\\s\\S]*?(?=##|$)`, "i")
  const m = t.match(re)
  return m? m[0].replace(new RegExp(`##\\s*${h}`,"i"),"").trim() : ""
}

if (!title) {
  // пробуем взять первую строку desc как title
  if (desc) { const first = desc.split("\n")[0].trim(); if (first.length>5 && first.length<120) { title = first; desc = desc.slice(first.length).trim() } }
}

if (!title || title.length<5) {
  console.log(JSON.stringify({ valid:false, error:"title required: минимум 5 символов, императив до ~80. Пример: 'Добавить воркфлоу-движок new-task с guardrails'", _reads:1 }))
  process.exit(1)
}
if (title.length>120) title = title.slice(0,120)

const context = extract("Контекст", desc) || extract("Context", desc)
const what = extract("Что сделать", desc) || extract("Что нужно сделать", desc)
const acceptance = extract("Критерии", desc) || extract("Критерии приёмки", desc)

// минимальное требование: либо desc с блоками, либо хотя бы title+desc 20 символов
const minimal = (context && what && acceptance) || (desc.length >= 20)
if (!minimal) {
  console.log(JSON.stringify({
    valid:false,
    error:"неполная задача: нужен либо шаблон ## Контекст / ## Что сделать / ## Критерии приёмки, либо desc ≥20 символов. Получено: title='"+title+"' desc_len="+desc.length,
    title, desc, _reads:1
  }))
  process.exit(1)
}

const outDesc = (context && what) ? desc : `## Контекст\n${context || desc.slice(0,200)}\n\n## Что сделать\n${what || "Сформулировать и декомпозировать по шагам"}\n\n## Критерии приёмки\n${acceptance || "- [ ] Карточка в Trello готова к Taken\n- [ ] Guardrails не нарушены"}`

console.log(JSON.stringify({ valid:true, title, desc: outDesc, context, what, acceptance, _reads:1 }))
