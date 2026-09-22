#!/usr/bin/env bun
// @ts-nocheck
// 03-recon — лёгкая разведка локально (без сети), возвращает facts для plan
// Смотрит .docs|docs|specs|.specs|documentation + tree + graphify (если есть)
// Выход: {facts:[], docs:{found}, code:{tree,graph}, _reads}

import { readFileSync, existsSync, readdirSync } from "fs"
import path from "path"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const title = data.validate?.title || data.input?.title || ""
const root = path.resolve(import.meta.dir, "../../..")

const docDirs = [".docs","docs","specs",".specs","documentation","documentations"]
const found: string[] = []
for (const d of docDirs) {
  const full = path.join(root, d)
  if (existsSync(full)) {
    try { const ents = readdirSync(full).slice(0,5); found.push(`${d}/: ${ents.join(", ")}`) } catch { found.push(`${d}/`) }
  }
}

let tree = ""
try {
  const proc = Bun.spawnSync(["bash","-c","ls -1 2>/dev/null | head -20"], { cwd: root })
  tree = proc.stdout.toString().trim().slice(0,500)
} catch {}

let graph = null
try {
  const proc = Bun.spawnSync(["bash", path.join(root,".opencode/scripts/graphify/run.sh"), "--json"], { cwd: root })
  const out = proc.stdout.toString().trim()
  if (out) graph = JSON.parse(out)
} catch { graph = null }

const facts = [
  `Задача: ${title}`.slice(0,120),
  found.length ? `Доки: ${found.join(" | ")}` : "Локальных доков .docs/docs/specs не найдено — пропустим фронт 1",
  graph ? `Граф: files=${graph.files?.length||graph.nodes||"?"} deps=${graph.edges||graph.deps||"?"}` : "Граф: graphify недоступен",
  `Дерево: ${tree.split("\n").slice(0,3).join(" | ").slice(0,120)}`,
]
if (/(react|компонент|ui)/i.test(title)) facts.push("needs_react: true — нужен react-architect")

console.log(JSON.stringify({ facts, docs:{found}, code:{ tree: tree.slice(0,300), graph: graph? {files: graph.files?.length||null, raw: String(JSON.stringify(graph)).slice(0,300)}:null }, open_questions:[], _reads:2 }))
