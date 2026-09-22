#!/usr/bin/env bun
// @ts-nocheck
// 01-precommit — обязательный коммит перед workflow, чтобы можно было вернуться. Idempotent.
// Вход: {input:{file:"src/...tsx"}, ...}
// Выход: {committed, commit, _writes}

import { readFileSync, existsSync } from "fs"
import path from "path"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const file = data.input?.file || data.file || data.validate?.file
if (!file) { console.log(JSON.stringify({ error:"input.file required: src/...tsx", _writes:0 })); process.exit(1) }

const root = path.resolve(import.meta.dir, "../../..")
const full = path.join(root, file)
if (!existsSync(full)) { console.log(JSON.stringify({ error:`file not found: ${file}`, _writes:0 })); process.exit(1) }

// проверяем dirty — если есть изменения, коммитим
let status = Bun.spawnSync(["git","status","--porcelain", file], { cwd: root })
let dirty = status.stdout.toString().trim()
let diffStat = ""
try { diffStat = Bun.spawnSync(["git","diff","--stat"], {cwd:root}).stdout.toString().trim().slice(0,500) } catch {}

if (!dirty) {
  // уже чисто — делаем пустой коммит-метку если нужно, иначе пропускаем
  console.log(JSON.stringify({ committed:false, commit:null, note:"working tree clean — precommit skipped, можно вернуться к HEAD", file, _writes:0 }))
  process.exit(0)
}

// коммитим именно этот файл
let add = Bun.spawnSync(["git","add", file], {cwd:root})
if (add.exitCode!==0) { console.log(JSON.stringify({ error:add.stderr.toString(), _writes:0 })); process.exit(1) }
let msg = `chore(decompose): pre-backup for ${file} — can revert to this`
let commit = Bun.spawnSync(["git","commit","-m", msg], {cwd:root})
if (commit.exitCode!==0) {
  // если нечего коммитить — ок
  if (commit.stderr.toString().includes("nothing to commit")) {
    console.log(JSON.stringify({ committed:false, commit:null, note:"nothing to commit", _writes:0 }))
    process.exit(0)
  }
  console.log(JSON.stringify({ error: commit.stderr.toString() + commit.stdout.toString(), _writes:0 })); process.exit(1)
}
let rev = Bun.spawnSync(["git","rev-parse","HEAD"], {cwd:root}).stdout.toString().trim()
console.log(JSON.stringify({ committed:true, commit: rev.slice(0,8), message: msg, file, _writes:1 }))
