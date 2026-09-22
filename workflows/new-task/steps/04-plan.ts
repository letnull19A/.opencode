#!/usr/bin/env bun
// @ts-nocheck
// 04-plan — собирает Trello-план карточек (без сети), использует facts из recon + approach из classify
// Выход: {cards:[{title,desc,list}], complexity, risk, _reads}

import { readFileSync } from "fs"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const title = data.validate?.title || data.input?.title || "Новая задача"
const approach = data.classify?.approach || "update"
const facts = data.recon?.facts || []
const context = data.validate?.context || ""
const what = data.validate?.what || ""
const acceptance = data.validate?.acceptance || ""

let cards
if (approach === "new-module") {
  cards = [
    { title: `${title} — проектирование`, list: "Backlog", desc: `## Контекст\n${context || facts.join("\n")}\n\n## Что сделать\nСпроектировать модуль по подходу new-module (decompose>delete>update>add)\n\n## Критерии приёмки\n- [ ] Спека в specs/\n- [ ] Граф зависимостей` },
    { title: `${title} — реализация`, list: "Backlog", desc: `## Контекст\nСвязано с проектированием\n\n## Что сделать\nРеализовать по спеке\n\n## Критерии приёмки\n- [ ] Тесты зелёные\n- [ ] ${acceptance || "Приёмка выполнена"}` },
  ]
} else if (approach === "decompose") {
  cards = [
    { title: `${title} — разбить на подзадачи`, list: "Backlog", desc: `## Контекст\n${facts.join("\n")}\n\n## Что сделать\nДекомпозировать большой модуль на мелкие (1 файл/пункт)\n\n## Критерии приёмки\n- [ ] Карточки заведены` },
  ]
} else {
  cards = [
    { title: title, list: "Backlog", desc: data.validate?.desc || `## Контекст\n${facts.join("\n")}\n\n## Что сделать\n${what || title}\n\n## Критерии приёмки\n${acceptance || "- [ ] Готово к Taken"}` },
  ]
}

const complexity = cards.length > 1 ? "M" : "S"
const risk = approach === "decompose" ? "medium" : "low"

console.log(JSON.stringify({ cards, complexity, risk, approach, _reads:1 }))
