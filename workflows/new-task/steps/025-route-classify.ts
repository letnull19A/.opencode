#!/usr/bin/env bun
// @ts-nocheck
// 025-route-classify — классифицирует единицу роута по таблице-правилу skills/routing/SKILL.md
// Правило: skills/routing/SKILL.md#классификатор-таблица (карточка 2) — два вопроса
// «нужен ли login?» / «мешает ли login?» → public/auth/unauth. Срабатывает до plan.
// Вход: {validate:{title,desc}, classify:{approach,...}} — единица страница|модуль (фронт) или эндпоинт|модуль (бэк)
// Выход: {route_unit, route_side, route_type, needs_login, login_blocks, applies, confidence, reason, rule, _reads}
// Матрица complex (карточка 4 — выполнено): этот шаг даёт фактор 1 (роутинг) в
// skills/evol-plan/SKILL.md#2b (роутинг × роль × слой × вложенность); компиляция — 04-plan.ts.
// Граф-карта Blocked by поверх фактора 4 — skills/nesting/SKILL.md; здесь не строить.

import { readFileSync } from "fs"
function arg(n:string){ const i=process.argv.indexOf(n); return i!==-1?process.argv[i+1]:undefined }
const p = arg("--input")
let data:any={}
try { data = JSON.parse(readFileSync(p!,"utf-8")) } catch {}
const title = data.validate?.title || data.input?.title || data.title || ""
const desc = data.validate?.desc || data.input?.desc || data.desc || ""
const text = `${title} ${desc}`.toLowerCase()

const RULE = "skills/routing/SKILL.md#классификатор-таблица"

// Сигналы единицы (фронт — страница|модуль, бэк — эндпоинт|модуль)
const hasPage = /(страниц|page|экран|screen|лендинг|landing|дашборд|dashboard)/i.test(text)
const hasModule = /(модул|module|компонент|component|виджет|widget)/i.test(text)
const hasEndpoint = /(эндпоинт|endpoint|api\/|бэк|backend|хендлер|handler|контроллер|controller)/i.test(text)
  || /(GET|POST|PUT|PATCH|DELETE)\s+\//i.test(text) // «METHOD /path» — явный признак бэк-эндпоинта
const hasRouteSignal = hasPage || hasModule || hasEndpoint
  || /(роут|route|навигац|navigation|guard-ы|route guard|guard маршрута|охранник маршрута|редирект|redirect|вход|login|регистрац|register|каталог|catalog|профил|profile|health)/i.test(text)

if (!hasRouteSignal) {
  console.log(JSON.stringify({
    route_unit: "none", route_side: "none", route_type: "none",
    needs_login: false, login_blocks: false, applies: false,
    confidence: 0.9, reason: "роут-сигналов нет — задача не про страницу|модуль|эндпоинт, шаг пропущен",
    rule: RULE, _reads: 1
  }))
  process.exit(0)
}

// Сторона: фронт / бэк / обе (смешанная единица — делится на модули, каждый типируется отдельно)
const frontSig = /(страниц|page|экран|фронт|frontend|jsx|tsx|компонент|лендинг|дашборд|виджет)/i.test(text)
const backSig = /(эндпоинт|endpoint|api\/|бэк|backend|хендлер|handler|401|403|контроллер)/i.test(text)
  || /(GET|POST|PUT|PATCH|DELETE)\s+\//i.test(text)
const route_side = (frontSig && backSig) ? "both" : backSig ? "back" : "front"

// Единица классификации
const route_unit = hasEndpoint ? "эндпоинт" : hasPage ? "страница" : "модуль"

// Два вопроса таблицы: «нужен ли login?» / «мешает ли login?»
// Порядок — по граничным правилам: сначала сильные unauth-маркеры
// (страница входа/регистрация/восстановление), затем auth, затем голый вход/login
// (бэк-эндпоинт login по таблице — unauth), иначе public.
const unauthStrong = /(регистрац|register|восстановл|restore|страница входа|экран входа|форма (входа|login)|только для гостей|гостевой)/i.test(text) // unauth
const healthPublic = /(health|health-check|healthy)/i.test(text) // граничное: health-check всегда public
const loginNeeded = /(дашборд|dashboard|профил|profile|личный|настройк|settings|заказ|order|корзин|подписк|subscription|только для (авторизован|пользовател|залогинен)|нужна авторизац|требует входа|admin|owner|401|403|приватн)/i.test(text) // auth
const loginBare = /(вход|login)/i.test(text) // голый вход/login без auth-контекста — unauth (POST /api/auth/login)
const publicSig = /(лендинг|landing|помощь|help|каталог|catalog|публичн|документ|docs|главная)/i.test(text) // public

let route_type = "public"
let reason = "сигналов login нет — public по умолчанию, при споре уточнить вручную"
let confidence = 0.6
if (unauthStrong) { route_type = "unauth"; reason = "login мешает (только для гостей): вход/регистрация/восстановление"; confidence = 0.85 }
else if (healthPublic) { route_type = "public"; reason = "граничное правило: health-check всегда public"; confidence = 0.95 }
else if (loginNeeded) { route_type = "auth"; reason = "нужен login: дашборд/профиль/заказы или явное требование авторизации"; confidence = 0.8 }
else if (loginBare) { route_type = "unauth"; reason = "голый вход/login без auth-контекста (POST /api/auth/login — unauth)"; confidence = 0.7 }
else if (publicSig) { route_type = "public"; reason = "не нужен и не мешает: лендинг/каталог/публичный документ"; confidence = 0.8 }

console.log(JSON.stringify({
  route_unit, route_side, route_type,
  needs_login: route_type === "auth",
  login_blocks: route_type === "unauth",
  applies: true, confidence, reason, rule: RULE, _reads: 1
}))
