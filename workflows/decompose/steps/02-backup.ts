#!/usr/bin/env bun
// @ts-nocheck
// 02-backup — оставляет файл, делает копию {name}_old.{ext} как образец. Не удаляет оригинал.
// Вход: {input:{file}, precommit:{...}}
// Выход: {backup, lines, overThreshold, _writes}

import { readFileSync, existsSync, copyFileSync, statSync } from "fs"
import path from "path"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const file = data.input?.file || data.file || ""
const root = path.resolve(import.meta.dir, "../../..")
const full = path.join(root, file)
if (!existsSync(full)) { console.log(JSON.stringify({error:`file not found ${file}`, _writes:0})); process.exit(1) }

const content = readFileSync(full,"utf-8")
const lines = content.split("\n").length
const threshold = 100
const over = lines > threshold

// _old имя: foo.tsx → foo_old.tsx, foo.test.ts → foo_old.test.ts (просто _old перед ext)
const dir = path.dirname(full)
const base = path.basename(full)
const ext = path.extname(base)
const name = base.slice(0, base.length - ext.length)
const backupName = `${name}_old${ext}`
const backupFull = path.join(dir, backupName)
const backupRel = path.join(path.dirname(file), backupName)

if (!existsSync(backupFull)) {
  copyFileSync(full, backupFull)
}

console.log(JSON.stringify({
  backup: backupRel,
  file,
  lines,
  target: "20-50",
  overThreshold: over,
  note: over ? `Кандидат на декомпозицию: ${lines} > ${threshold}` : `Ниже порога ${threshold} — декомпозиция опциональна`,
  _writes: 1
}))
