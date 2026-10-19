#!/usr/bin/env bun
// @ts-nocheck
// 02-classify — вызывает classify_plan (heuristic) или локальную эвристику как fallback
// Вход: {validate:{title,desc}, input:{}, ...}
// Выход: {approach, needs_react, confidence, reason, provider, _reads}

import { readFileSync } from "fs"
import path from "path"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const title = data.validate?.title || data.input?.title || data.title || ""
const desc = data.validate?.desc || data.input?.desc || data.desc || ""
const text = `${title} ${desc}`.toLowerCase()

let hasCode = false
try {
  const glob = Bun.spawnSync(["bash","-c","ls -1 src 2>/dev/null | head -5"])
  hasCode = (glob.stdout?.toString().trim().length||0) > 0
} catch {}

const isReact = /(react|компонент|ui|frontend|jsx|tsx|hook|props)/i.test(text)
let approach = "update"
let reason = "доработка существующего"
if (/(создать.*модул|новый модул|с нуля|new module|from scratch)/i.test(text)) { approach="new-module"; reason="создание модуля с нуля" }
else if (/(декомпоз|разбить|разделить|большой модул)/i.test(text)) { approach="decompose"; reason="декомпозиция большого модуля" }
else if (/(внедр|добавить функц|расшир|улучш|доработ)/i.test(text)) { approach="update"; reason="внедрение нового функционала" }
else if (!hasCode) { approach="new-module"; reason="кода нет — новый модуль" }

console.log(JSON.stringify({ approach, needs_react: isReact, confidence: hasCode||/(создать|новый|декомпоз)/i.test(text)?0.8:0.6, reason, provider:"heuristic", has_code:hasCode, _reads:1 }))
