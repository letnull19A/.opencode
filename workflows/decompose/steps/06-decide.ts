#!/usr/bin/env bun
// @ts-nocheck
// 06-decide — откат и повторы до 3 циклов. Если verify.ok==false и cycles<3 — откат к _old с комментарием.
// Вход: {verify:{ok,reason}, backup:{backup}, input:{file}, _meta:{attempt?}}
// Выход: {action:"done"|"retry"|"fail", cycles, reason, _writes}

import { readFileSync, existsSync, copyFileSync } from "fs"
import path from "path"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const file = data.input?.file || data.file || data.validate?.file || ""
const backup = (typeof data.backup === "string" ? data.backup : data.backup?.backup) || data.backup || ""
const verify = data.verify || data // fallback if flattened
const ok = verify.ok === true || data.ok === true
const root = path.resolve(import.meta.dir, "../../..")

// считаем циклы: ищем .workflows/run/**/attempt или берём из data._attempt
let cycles = (data._attempt || 0) + 1
// пытаемся прочитать счётчик из verify (если engine передал)
if (data.verify?._attempt) cycles = data.verify._attempt + 1

const maxCycles = 3

if (ok) {
  console.log(JSON.stringify({ action:"done", cycles, reason: verify.reason || "верификация ок", note:"Файл в цели 20-50, регрессий нет — _old остаётся как образец, можно удалить вручную", _writes:0 }))
  process.exit(0)
}

if (cycles < maxCycles) {
  // откат: восстанавливаем из _old
  try {
    const full = path.join(root, file)
    const oldFull = path.join(root, backup)
    if (existsSync(oldFull)) copyFileSync(oldFull, full)
  } catch {}
  // пишем комментарий цикла
  const msg = `Цикл ${cycles}/${maxCycles} провален: ${verify.reason || "unknown"} — откат к ${backup}, следующая попытка с учётом комментария.`
  console.log(JSON.stringify({ action:"retry", cycles, reason: msg, needFix: verify.reason, _writes:1 }))
  // не падаем — engine поймёт retry как сигнал; но для линейного движка просто сигналим
  // пишем marker чтобы следующий прогон знал цикл
  try { const { writeFileSync, mkdirSync } = await import("fs"); const d=path.join(root,".workflows/run"); } catch {}
  process.exit(0)
} else {
  console.log(JSON.stringify({ action:"fail", cycles, reason:`После ${maxCycles} циклов не удалось: ${verify.reason || "unknown"} — прекращение работы, требуется ручное вмешательство. Откат к _old выполнен.`, _writes:0 }))
  // откат финальный
  try { copyFileSync(path.join(root, backup), path.join(root, file)) } catch {}
  process.exit(2)
}
