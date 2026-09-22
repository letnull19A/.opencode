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

// базовая эвристика → абстрактный XML без привязки к UI-киту
let xml = `<Page>\n`
if (hasHeader) xml += `  <Header>\n    <Nav />\n    <Actions />\n  </Header>\n`
xml += `  <Main>\n`
if (hasForm) xml += `    <Filters>\n      <Field />\n      <Field />\n    </Filters>\n`
if (hasList) {
  xml += `    <List>\n`
  xml += `      <ListHeader />\n`
  xml += `      <Items>\n`
  xml += `        <Item>\n`
  xml += `          <Content />\n`
  xml += `          <Meta />\n`
  xml += `        </Item>\n`
  xml += `      </Items>\n`
  xml += `      <Empty />\n`
  xml += `      <Pagination />\n`
  xml += `    </List>\n`
} else if (hasCard) {
  xml += `    <Card>\n      <CardHeader />\n      <CardBody />\n      <CardFooter />\n    </Card>\n`
} else {
  xml += `    <Section>\n      <Content />\n    </Section>\n`
}
xml += `    <States>\n      <Loading />\n      <Error />\n    </States>\n`
xml += `  </Main>\n`
xml += `</Page>`

const nodes = (xml.match(/<(\w+)/g) || []).map(s=>s.slice(1))

console.log(JSON.stringify({
  conceptXml: xml,
  nodes,
  hint: "Абстрактный концепт: только вложенность и ответственность, без тегов/пропсов. Следующий шаг — реализация.",
  _reads: 1
}))
