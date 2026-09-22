#!/usr/bin/env bun
// @ts-nocheck
// 05-verify — два исхода: точечные тесты ИЛИ статистическое сравнение со старым.
// Сравнивает _old образец с новой реализацией: строки, отсутствие потерь, тесты.
// Вход: {input:{file}, backup:{backup,lines}, plan:{splits}}
// Выход: {ok, reason, stats:{oldLines,newLines}, testResult, _reads}

import { readFileSync, existsSync } from "fs"
import path from "path"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const file = data.input?.file || data.file || data.validate?.file || ""
const backup = (typeof data.backup === "string" ? data.backup : data.backup?.backup) || data.backup || ""
const root = path.resolve(import.meta.dir, "../../..")
const full = path.join(root, file)
const oldFull = path.join(root, backup)

let oldLines=0, newLines=0, oldContent="", newContent=""
try { oldContent = readFileSync(oldFull,"utf-8"); oldLines = oldContent.split("\n").length } catch {}
try { newContent = readFileSync(full,"utf-8"); newLines = newContent.split("\n").length } catch {}

let testOk: boolean | null = null
let testReason = ""
// пробуем точечные тесты — ищем команду из package.json/scripts
let testCmd=""
try {
  const pkg = JSON.parse(readFileSync(path.join(root,"package.json"),"utf-8"))
  if (pkg.scripts?.test) testCmd = "npm test"
  else if (existsSync(path.join(root,"bun.lockb"))) testCmd = "bun test"
} catch {}
if (testCmd) {
  try {
    const proc = Bun.spawnSync(testCmd.split(" "), { cwd: root, stdout:"pipe", stderr:"pipe" })
    testOk = proc.exitCode===0
    testReason = testOk ? `тесты зелёные (${testCmd})` : `тесты упали (${testCmd} exit ${proc.exitCode})`
  } catch { testOk=null; testReason="тесты не запустились" }
}

// статистическое сравнение: новый файл должен быть 20-50 строк, не терять экспорты
let exportsOld = (oldContent.match(/export\s+(function|const|type|interface)/g)||[]).length
let exportsNew = (newContent.match(/export\s+(function|const|type|interface)/g)||[]).length
let lostExports = exportsOld - exportsNew

let ok = true
let reason = ""
if (newLines > 80) { ok=false; reason=`не влезли в цель 20-50: сейчас ${newLines} строк — дроби мельче` }
else if (lostExports > 0) { ok=false; reason=`потеряны экспорты: было ${exportsOld}, стало ${exportsNew} — регрессия` }
else if (testOk===false) { ok=false; reason=testReason }
else if (testOk===null) {
  // без тестов — статистически
  reason = `без тестов: старый ${oldLines} → новый ${newLines}, экспорты ${exportsOld}→${exportsNew} — ок если не потеряно`
  ok = lostExports <=0
} else {
  reason = testReason + `, ${oldLines}→${newLines} строк`
}

console.log(JSON.stringify({ ok, reason, stats:{oldLines,newLines,exportsOld,exportsNew}, testOk, testReason, _reads:1 }))
