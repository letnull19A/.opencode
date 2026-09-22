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

// маппинг абстракт → конкретный тег/компонент + слой + data-flow (props vs Context)
function mapAbstract(tag:string){
  const m:any = {
    App: { tag:"div", comp:"App", file:"app/App.tsx", props:"initConfig only", layer:"app", data:"Context providers (router, i18n, theme) — без внешних props" },
    Layout: { tag:"div", comp:"MainLayout", file:"app/layouts/MainLayout.tsx", props:"children, variant", layer:"layout", data:"composition (children) — без data-логики, без Context" },
    Page: { tag:"main", comp:"TaskPage", file:"app/pages/TaskPage.tsx", props:"— (via Context)", layer:"page", data:"Context/state-manager + Suspense/ErrorBoundary — props минимизировать" },
    Header: { tag:"header", comp:"Header", file:"app/layouts/Header.tsx", props:"children", layer:"layout", data:"composition — props избегай" },
    Nav: { tag:"nav", comp:"Nav", file:"shared/uikit/Nav.tsx", props:"items: NavItem[]", layer:"shared", data:"props — uikit ок" },
    Actions: { tag:"div", comp:"Actions", file:"components/Actions.tsx", props:"onAction", layer:"component", data:"props (uikit) или Context" },
    Main: { tag:"main", comp:"Main", file:"app/layouts/Main.tsx", props:"children", layer:"layout", data:"composition" },
    Filters: { tag:"form", comp:"Filters", file:"components/Filters.tsx", props:"— (via FiltersContext)", layer:"component", data:"Context/state-manager — не пробрасывать через layout" },
    Field: { tag:"input", comp:"Field", file:"shared/uikit/Field.tsx", props:"label, value, onChange", layer:"shared", data:"props — uikit" },
    List: { tag:"section", comp:"List", file:"components/List.tsx", props:"— (via ListContext)", layer:"component", data:"Context — избежать prop-drilling" },
    ListHeader: { tag:"div", comp:"ListHeader", file:"components/ListHeader.tsx", props:"title, count (via Context)", layer:"component", data:"Context" },
    Items: { tag:"ul", comp:"Items", file:"components/Items.tsx", props:"children", layer:"component", data:"composition" },
    Item: { tag:"li", comp:"ListItem", file:"components/ListItem.tsx", props:"item (via Context) | onSelect", layer:"component", data:"Context + callback" },
    Card: { tag:"article", comp:"Card", file:"components/Card.tsx", props:"— (via CardContext)", layer:"component", data:"Context" },
    CardHeader: { tag:"header", comp:"CardHeader", file:"shared/uikit/CardHeader.tsx", props:"title", layer:"shared", data:"props" },
    CardBody: { tag:"div", comp:"CardBody", file:"components/CardBody.tsx", props:"children", layer:"component", data:"composition" },
    CardFooter: { tag:"footer", comp:"CardFooter", file:"components/CardFooter.tsx", props:"children", layer:"component", data:"composition" },
    Content: { tag:"div", comp:"Content", file:"components/Content.tsx", props:"children", layer:"component", data:"composition" },
    Meta: { tag:"div", comp:"Meta", file:"components/Meta.tsx", props:"meta (via Context)", layer:"component", data:"Context" },
    Section: { tag:"section", comp:"Section", file:"components/Section.tsx", props:"children", layer:"component", data:"composition" },
    Empty: { tag:"div", comp:"EmptyState", file:"shared/uikit/EmptyState.tsx", props:"message", layer:"shared", data:"props — uikit" },
    Pagination: { tag:"nav", comp:"Pagination", file:"shared/uikit/Pagination.tsx", props:"page, total, onChange", layer:"shared", data:"props — uikit" },
    States: { tag:"div", comp:"States", file:"components/States.tsx", props:"loading, error (via Context)", layer:"component", data:"Context" },
    Loading: { tag:"div", comp:"Loading", file:"shared/uikit/Loading.tsx", props:"—", layer:"shared", data:"—" },
    Error: { tag:"div", comp:"ErrorState", file:"shared/uikit/ErrorState.tsx", props:"error, onRetry", layer:"shared", data:"props" },
    Component: { tag:"div", comp:"Component", file:"components/Component.tsx", props:"children", layer:"component", data:"composition" },
  }
  return m[tag] || { tag:"div", comp:tag, file:`components/${tag}.tsx`, props:"children", layer:"component", data:"props/Context" }
}

function parseConcept(xml:string){
  // извлекаем <Component name="X"/> и обычные теги <App>/<Layout>/<Page>
  const comps = [...xml.matchAll(/<Component name="([^"]+)"/g)].map(m=>m[1])
  const layers = [...xml.matchAll(/<(App|Layout|Page)/g)].map(m=>m[1])
  const tags = [...new Set([...layers, ...comps])]
  return tags
}

const tags = parseConcept(xml)
const components = tags.map(t=>{
  const c = mapAbstract(t)
  return { abstract: t, layer: c.layer, component: c.comp, tag: c.tag, file: c.file, props: c.props, data: c.data, style: useTailwind ? "tailwind" : "css-modules" }
})

const fileMap = components.map(c=>`${c.file} [${c.layer}] → <${c.tag}> as ${c.component} (${c.props}) — ${c.data}`).join("\n")

const dataFlow = `**Data-flow (слои app/layout/page/component/shared):**\n- app: только init-конфиг, провайдеры (router, theme, i18n) — без внешних props\n- layout: расположение без data-логики, props избегай → composition (children)\n- page: логика + Suspense/ErrorBoundary, потребляет Context/state-manager — props минимизировать\n- component: fragments (FSD widgets/features) — Context/props по необходимости\n- shared/uikit: props ок, массово переиспользуемое\nВладелец состояния — ближайший общий предок; через layout/page — Context/state-manager, не prop-drilling. server-state vs client-state разделяй.`

const markdown = `### Концепт (XML со слоями app→layout→page→component→shared)\n\`\`\`xml\n${xml}\n\`\`\`\n\n### Реализация\n| Абстракт | Слой | Компонент | Тег | Файл | Props/Data |\n|---|---|---|---|---|---|\n${components.map(c=>`| ${c.abstract} | ${c.layer} | ${c.component} | \`<${c.tag}>\` | \`${c.file}\` | ${c.props} — ${c.data} |`).join("\n")}\n\n${dataFlow}\n\n**Стек:** ${isNext? "Next.js": "React"} + ${useTailwind? "Tailwind":"CSS Modules"} — по проекту, стандарты команды (linters/CODE_OF_CONDUCT/README) выше слоёв.\n**Файлы:**\n\`\`\`\n${fileMap}\n\`\`\``

console.log(JSON.stringify({
  implementation: { components, fileMap },
  markdown,
  conceptXml: xml,
  _reads: 1
}))
