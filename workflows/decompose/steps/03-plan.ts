#!/usr/bin/env bun
// @ts-nocheck
// 03-plan — планирует на что разбить: хуки, компоненты, типы. Читает файл, предлагает splits.
// Вход: {input:{file}, backup:{...}}
// Выход: {splits:[{kind,file,hint}], plan, _reads}

import { readFileSync } from "fs"
import path from "path"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const file = data.input?.file || data.file || ""
const root = path.resolve(import.meta.dir, "../../..")
const full = path.join(root, file)
let content=""
try { content = readFileSync(full,"utf-8") } catch { console.log(JSON.stringify({error:`read fail ${file}`, _reads:0})); process.exit(1) }

const lines = content.split("\n")
const hasHooks = /use[A-Z]\w*\(|function use\w+|const use\w+/.test(content)
const hasTypes = /type\s+\w+|interface\s+\w+|enum\s+\w+/.test(content)
const hasComponents = /function\s+[A-Z]\w*|const\s+[A-Z]\w*\s*=.*=>|<[A-Z]\w+/.test(content)
const hasUtils = /export\s+function|export\s+const.*=>/.test(content) && content.length>2000
const hasStyles = /styled\(|makeStyles|tailwind|className/.test(content)

const splits:any[]=[]
const dir = path.dirname(file)
const base = path.basename(file, path.extname(file))

if (hasTypes) splits.push({ kind:"types", file: `${dir}/${base}.types.ts`, hint:"Вынести type/interface/enum — чистые контракты" })
if (hasHooks) splits.push({ kind:"hooks", file: `${dir}/hooks/use${base}.ts`, hint:"Вынести логику в хук — отделить от JSX" })
if (hasComponents && lines.length>100) splits.push({ kind:"components", file: `${dir}/components/${base}Parts.tsx`, hint:"Вынести презентационные куски — один компонент одна ответственность" })
if (hasUtils) splits.push({ kind:"utils", file: `${dir}/${base}.utils.ts`, hint:"Вынести чистые функции" })
if (!splits.length) splits.push({ kind:"components", file: `${dir}/${base}.parts.tsx`, hint:"Разбить по ответственности — composition вместо монолита" })

// если файл уже 20-50 после плана — ок
const plan = `Декомпозиция ${file} (${lines.length} строк → цель 20-50):\n` + splits.map(s=>`- [${s.kind}] ${s.file} — ${s.hint}`).join("\n")

console.log(JSON.stringify({ splits, plan, lines: lines.length, _reads:1 }))
