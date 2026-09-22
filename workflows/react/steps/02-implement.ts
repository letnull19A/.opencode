#!/usr/bin/env bun
// @ts-nocheck
// 02-implement — конкретика: маппит абстрактный XML → чёткие компоненты/теги/props/файлы
// Вход: {concept:{conceptXml,nodes}, input:{title,desc}, validate, ...}
// Выход: {implementation:{components, fileMap}, markdown, _reads}

import { readFileSync } from "fs"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}

const title = data.validate?.title || data.input?.title || "Компонент"
const xml = data.concept?.conceptXml || data.conceptXml || "<Page><Main><Section><Content/></Section></Main></Page>"
const text = `${title} ${(data.validate?.desc||"")}`.toLowerCase()
const useTailwind = /(tailwind)/i.test(text)
const isNext = /(next)/i.test(text)

// маппинг абстракт → конкретный тег/компонент
function mapAbstract(tag:string){
  const m:any = {
    Page: { tag:"div", comp:"Page", file:"components/Page.tsx", props:"children" },
    Header: { tag:"header", comp:"Header", file:"components/Header.tsx", props:"children" },
    Nav: { tag:"nav", comp:"Nav", file:"components/Nav.tsx", props:"items: NavItem[]" },
    Actions: { tag:"div", comp:"Actions", file:"components/Actions.tsx", props:"onAction" },
    Main: { tag:"main", comp:"Main", file:"components/Main.tsx", props:"children" },
    Filters: { tag:"form", comp:"Filters", file:"components/Filters.tsx", props:"value, onChange" },
    Field: { tag:"input", comp:"Field", file:"components/Field.tsx", props:"label, value, onChange" },
    List: { tag:"section", comp:"List", file:"components/List.tsx", props:"items, renderItem" },
    ListHeader: { tag:"div", comp:"ListHeader", file:"components/ListHeader.tsx", props:"title, count" },
    Items: { tag:"ul", comp:"Items", file:"components/Items.tsx", props:"children" },
    Item: { tag:"li", comp:"ListItem", file:"components/ListItem.tsx", props:"item, onSelect" },
    Card: { tag:"article", comp:"Card", file:"components/Card.tsx", props:"item" },
    CardHeader: { tag:"header", comp:"CardHeader", file:"components/CardHeader.tsx", props:"title" },
    CardBody: { tag:"div", comp:"CardBody", file:"components/CardBody.tsx", props:"children" },
    CardFooter: { tag:"footer", comp:"CardFooter", file:"components/CardFooter.tsx", props:"actions" },
    Content: { tag:"div", comp:"Content", file:"components/Content.tsx", props:"children" },
    Meta: { tag:"div", comp:"Meta", file:"components/Meta.tsx", props:"meta" },
    Section: { tag:"section", comp:"Section", file:"components/Section.tsx", props:"children" },
    Empty: { tag:"div", comp:"EmptyState", file:"components/EmptyState.tsx", props:"message" },
    Pagination: { tag:"nav", comp:"Pagination", file:"components/Pagination.tsx", props:"page, total, onChange" },
    States: { tag:"div", comp:"States", file:"components/States.tsx", props:"loading, error" },
    Loading: { tag:"div", comp:"Loading", file:"components/Loading.tsx", props:"" },
    Error: { tag:"div", comp:"ErrorState", file:"components/ErrorState.tsx", props:"error, onRetry" },
  }
  return m[tag] || { tag:"div", comp:tag, file:`components/${tag}.tsx`, props:"children" }
}

const tags = (xml.match(/<(\w+)/g)||[]).map(s=>s.slice(1))
const uniq = [...new Set(tags)]
const components = uniq.map(t=>{
  const c = mapAbstract(t)
  return { abstract: t, component: c.comp, tag: c.tag, file: c.file, props: c.props, style: useTailwind ? "tailwind" : "css-modules" }
})

const fileMap = components.map(c=>`${c.file} → <${c.tag}> as ${c.component} (${c.props})`).join("\n")

const markdown = `### Концепт (XML)\n\`\`\`xml\n${xml}\n\`\`\`\n\n### Реализация\n| Абстракт | Компонент | Тег | Файл | Props |\n|---|---|---|---|---|\n${components.map(c=>`| ${c.abstract} | ${c.component} | \`<${c.tag}>\` | \`${c.file}\` | ${c.props} |`).join("\n")}\n\n**Стек:** ${isNext? "Next.js": "React"} + ${useTailwind? "Tailwind":"CSS Modules"} — по задаче, без навязывания.\n**Поток:** Page (container) owns state → Filters/List/States (presentation), хук useList для данных.`

console.log(JSON.stringify({
  implementation: { components, fileMap },
  markdown,
  conceptXml: xml,
  _reads: 1
}))
