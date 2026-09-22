#!/usr/bin/env bun
// @ts-nocheck
// 01-concept — абстрактная XML-разметка: вложенность и структура без конкретики
// Вход: {input:{title,desc}, validate:{title,desc}, _meta}
// Выход: {conceptXml, nodes:[], _reads}

import { readFileSync } from "fs"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const title = data.validate?.title || data.input?.title || data.title || "Компонент"
const desc = data.validate?.desc || data.input?.desc || data.desc || ""

const text = `${title} ${desc}`.toLowerCase()
const hasList = /(список|list|таблица|grid|feed)/i.test(text)
const hasForm = /(форма|form|input|фильтр|filter)/i.test(text)
const hasCard = /(карточка|card|item)/i.test(text)
const hasHeader = /(шапка|header|нав|nav)/i.test(text)

// базовая эвристика → абстрактный XML по слоям app→layout→page→component→shared
let inner = ""
if (hasForm) inner += `      <Component name="Filters"><Component name="Field"/><Component name="Field"/></Component>\n`
if (hasList) {
  inner += `      <Component name="List">\n`
  inner += `        <Component name="ListHeader"/>\n`
  inner += `        <Component name="Items"><Component name="Item"><Component name="Content"/><Component name="Meta"/></Component></Component>\n`
  inner += `        <Component name="Empty"/><Component name="Pagination"/>\n`
  inner += `      </Component>\n`
} else if (hasCard) {
  inner += `      <Component name="Card"><Component name="CardHeader"/><Component name="CardBody"/><Component name="CardFooter"/></Component>\n`
} else {
  inner += `      <Component name="Section"><Component name="Content"/></Component>\n`
}
inner += `      <Component name="States"><Component name="Loading"/><Component name="Error"/></Component>\n`

let xml = `<App>\n  <Layout variant="main">\n    <Page>\n${inner}    </Page>\n  </Layout>\n</App>`
if (hasHeader) {
  xml = `<App>\n  <Layout variant="main">\n    <Component name="Header"><Component name="Nav"/><Component name="Actions"/></Component>\n    <Page>\n${inner}    </Page>\n  </Layout>\n</App>`
}

const nodes = (xml.match(/<(\w+)/g) || []).map(s=>s.slice(1))

console.log(JSON.stringify({
  conceptXml: xml,
  nodes,
  layers: ["app","layout","page","component","shared"],
  hint: "Слои app→layout→page→component→shared (рекомендательно, стандарты команды выше). Layout без data-логики, app только init-конфиг.",
  _reads: 1
}))
