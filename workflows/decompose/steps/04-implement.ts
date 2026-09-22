#!/usr/bin/env bun
// @ts-nocheck
// 04-implement — переписывает реализацию по плану. Скелет: создаёт заглушки для splits, не ломая оригинал.
// Вход: {plan:{splits}, backup:{backup}, input:{file}}
// Выход: {written:[], note, _writes}
// Реальная логика — вынос хуков/типов/компонентов — делается агентом/LLM, здесь — каркас с guardrails.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "fs"
import path from "path"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const file = data.input?.file || data.file || ""
const splits:any[] = data.plan?.splits || []
const root = path.resolve(import.meta.dir, "../../..")

const written:string[]=[]
for (const s of splits) {
  const full = path.join(root, s.file)
  const dir = path.dirname(full)
  if (!existsSync(dir)) mkdirSync(dir, {recursive:true})
  if (existsSync(full)) continue // не перетираем если уже есть — идемпотентно
  let tpl=""
  if (s.kind==="types") tpl=`// ${s.file} — вынесенные типы из ${file}\nexport type ${path.basename(file, path.extname(file))}Props = {}\n`
  else if (s.kind==="hooks") tpl=`// ${s.file} — хук из ${file}\nexport function use${path.basename(file, path.extname(file))}() { return {} }\n`
  else if (s.kind==="utils") tpl=`// ${s.file} — utils из ${file}\nexport const helper = () => {}\n`
  else tpl=`// ${s.file} — компонент из ${file}\nexport function Part(){ return null }\n`
  writeFileSync(full, tpl)
  written.push(s.file)
}

console.log(JSON.stringify({
  written,
  file,
  note: written.length ? `Созданы заглушки ${written.length} — дальше LLM/агент наполняет их реальным кодом, оригинал ${file} остаётся до verify` : "Заглушки уже существуют — идемпотентно",
  _writes: written.length
}))
