#!/usr/bin/env bun
// @ts-nocheck
// 04-plan — собирает Trello-план карточек (без сети), использует facts из recon + approach из classify
// + тип роута из route-classify (таблица skills/routing/SKILL.md): дописывает «Роут: …» в контекст карточек
// + закрытая матрица complex (карточка 4, skills/evol-plan/SKILL.md#2b-3b): при complex=true
// компилирует 4 фактора (роутинг × роль × слой × вложенность) в 4 строки контекста +
// критерии доступа + разрез по слоям + Blocked by. Граф-карта — skills/nesting/SKILL.md,
// здесь только интерфейс входа {nesting, blocked_by:[]}.
// Выход: {cards:[{title,desc,list}], complexity, risk, approach, complex, matrix, _reads}

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
const route = data["route-classify"] || {}
const text = `${title} ${data.validate?.desc || ""} ${facts.join(" ")}`.toLowerCase()

const routeLine = route.applies
  ? `Роут: ${route.route_unit || "?"} (${route.route_side || "?"}) → ${route.route_type || "?"} (правило: ${route.rule || "skills/routing/SKILL.md"})`
  : "Роут: none (не роутная задача)"
const routeSuffix = `\n\n${routeLine}`

// --- Матрица complex (карточка 4): закрытые значения, источники — только .opencode/ ---
// Фактор 2 — роль: строки «гость/пользователь» + граничное «admin/owner поверх auth» (skills/routing/SKILL.md)
let role = "user"
if (/(админ|admin)/i.test(text)) role = "admin"
else if (/(owner|владелец)/i.test(text)) role = "owner"
else if (/(гость|guest|аноним|неавторизован)/i.test(text)) role = "guest"
// Фактор 3 — слой: FSD shared→entities→features→widgets→pages→app (agent/refactor.md:56) + gateway|service (AGENTS.md Layout)
let layer = ""
const layerKw = [
  ["shared", /(shared|uikit|ui-кит)/i],
  ["entities", /(entit|сущност)/i],
  ["features", /(feature|фич)/i],
  ["widgets", /(widget|виджет)/i],
  ["pages", /(pages|страниц|page)/i],
  ["app", /(app\/|layout|лояут)/i],
  ["gateway", /(gateway|шлюз)/i],
  ["service", /(сервис|service|микросервис|бэк|backend|эндпоинт|endpoint|api\/)/i],
]
for (const [name, re] of layerKw) { if ((re as RegExp).test(text)) { layer = name as string; break } }
if (!layer) {
  const frontSig = /(страниц|page|фронт|frontend|tsx|jsx|компонент|лендинг|landing|дашборд|dashboard|экран)/i.test(text)
  const backSig = /(эндпоинт|endpoint|api\/|бэк|backend|сервис|service|gateway)/i.test(text)
  layer = backSig && !frontSig ? "service" : frontSig && !backSig ? "pages" : "features"
}
// Фактор 4 — вложенность: правила графа — skills/nesting/SKILL.md (здесь только вычисление in/out → nesting)
const blockedBy: string[] = data.validate?.blocked_by || data.recon?.blocked_by || []
let nesting = "unknown" // unknown-fallback по skills/nesting/SKILL.md: нет данных графа — не гадать root
if (blockedBy.length === 0 && data.recon?.blocks_others === true) nesting = "root"
else if (blockedBy.length > 0 && data.recon?.blocks_others === true) nesting = "branch"
else if (blockedBy.length > 0) nesting = "leaf"

const matrix = {
  route: route.applies ? (route.route_type || "public") : "none",
  role, layer, nesting,
  rule: "skills/evol-plan/SKILL.md#2b",
}
const matrixLines = [
  routeLine,
  `Роль: ${role} (guest|user — строки таблицы, admin|owner — поверх auth)`,
  `Слой: ${layer} (FSD shared→app + gateway|service; 1 карточка = 1 слой)`,
  `Вложенность: ${nesting} (root|branch|leaf|unknown — по Blocked by из dump/audit; правила — skills/nesting/SKILL.md)`,
].join("\n")
const matrixSuffix = `\n\n${matrixLines}`

// Порог complex (зафиксирован, skills/evol-plan/SKILL.md#2b):
// complex = (level==high) OR (level==medium AND risk in [medium,high]).
// На уровне workflow нет score — аппроксимация через approach/риск:
// decompose/new-module(2 карточки) ≈ medium+, риск medium (decompose) → complex.
let cards
if (approach === "new-module") {
  cards = [
    { title: `${title} — проектирование`, list: "Backlog", desc: `## Контекст\n${context || facts.join("\n")}\n\n## Что сделать\nСпроектировать модуль по подходу new-module (decompose>delete>update>add)\n\n## Критерии приёмки\n- [ ] Спека в specs/\n- [ ] Граф зависимостей${routeSuffix}` },
    { title: `${title} — реализация`, list: "Backlog", desc: `## Контекст\nСвязано с проектированием\n\n## Что сделать\nРеализовать по спеке\n\n## Критерии приёмки\n- [ ] Тесты зелёные\n- [ ] ${acceptance || "Приёмка выполнена"}${routeSuffix}` },
  ]
} else if (approach === "decompose") {
  cards = [
    { title: `${title} — разбить на подзадачи`, list: "Backlog", desc: `## Контекст\n${facts.join("\n")}\n\n## Что сделать\nДекомпозировать большой модуль на мелкие (1 файл/пункт)\n\n## Критерии приёмки\n- [ ] Карточки заведены${routeSuffix}` },
  ]
} else {
  const baseCtx = [context || facts.join("\n"), routeLine].filter(Boolean).join("\n")
  cards = [
    { title: title, list: "Backlog", desc: data.validate?.desc ? `${data.validate.desc}${routeLine ? `\n\n${routeLine}` : ""}` : `## Контекст\n${baseCtx}\n\n## Что сделать\n${what || title}\n\n## Критерии приёмки\n${acceptance || "- [ ] Готово к Taken"}` },
  ]
}

const complexity = cards.length > 1 ? "M" : "S"
const risk = approach === "decompose" ? "medium" : "low"
// Аппроксимация порога complex на уровне workflow (точный — в evol-plan по score):
const complex = approach === "decompose" || (cards.length > 1 && risk !== "low")

if (complex) {
  // Компиляция матрицы в план (#3b): 4 строки в контекст каждой карточки +
  // критерии доступа при auth/unauth (из таблицы routing).
  const accessCrit =
    matrix.route === "auth" ? "\n- [ ] Гость → редирект на вход / 401-403 (таблица routing)"
    : matrix.route === "unauth" ? "\n- [ ] Пользователь → редирект в приложение / 403 (таблица routing)"
    : ""
  cards = cards.map((c: any) => {
    if (typeof c.desc === "string" && c.desc.includes("Роль:")) return c
    // База уже содержит routeSuffix — заменяем его полной матрицей (там же первая строка — routeLine), без дубля
    const base = typeof c.desc === "string" && routeSuffix && c.desc.endsWith(routeSuffix)
      ? c.desc.slice(0, -routeSuffix.length)
      : c.desc
    return { ...c, desc: `${base}${matrixSuffix}${accessCrit}` }
  })
}

console.log(JSON.stringify({ cards, complexity, risk, approach, complex, matrix, _reads: 1 }))
