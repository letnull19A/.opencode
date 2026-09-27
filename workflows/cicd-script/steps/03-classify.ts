#!/usr/bin/env bun
// @ts-nocheck
// 03-classify — тип пайплайна + сложность + каких агентов задействовать + UNIX-профиль.
// Jev primary (classify:"cicd"), fallback — эвристика от target.pipeline + gaps.
// Вход: {survey:{...}, target:{target:{...}, gaps:[...]}, input:{title,desc}}
// Выход: {pipeline_type, complexity:{score,level}, agents:[{agent,why}], unix_style, confidence, reason, provider, _reads}

import { readFileSync } from "fs"
function arg(n: string) { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : undefined }
const p = arg("--input")
let data: any = {}
try { data = JSON.parse(readFileSync(p!, "utf-8")) } catch { }
const survey = data.survey || {}
// движок мержит top-level: data.target может быть {spec,gaps}, {target,gaps} или сплющенным spec
const tRaw = data.target || {}
const target = tRaw.spec || tRaw.target || (tRaw.pipeline ? tRaw : {}) || data.spec || {}
const gaps = tRaw.gaps || data.gaps || []
const title = data.input?.title || data.title || ""
const desc = data.input?.desc || data.desc || ""

const pipeline_type = target.pipeline || "ci-gate"

// эвристика сложности: база типа + 2 за gap + 1 за deploy не-none
const base: Record<string, number> = { "ci-gate": 3, "build-push": 5, "deploy": 6, "full": 9 }
let score = (base[pipeline_type] ?? 5) + gaps.length * 2 + (target.deploy && target.deploy !== "none" ? 1 : 0)
score = Math.min(score, 20)
const level = score <= 4 ? "low" : score <= 8 ? "medium" : "high"

const agents: any[] = [
  { agent: "recon", why: "углубить actual-state если gaps/неизвестный стек" },
  { agent: "evol-plan", why: "ревью плана стадий перед scaffold" },
]
const gapOwner: Record<string, string> = { dockerfile: "docker-pack", "ci-yaml": "ci-runner", tests: "unit-test" }
for (const g of gaps) {
  const a = g.owner_agent || gapOwner[g.id]
  if (a && a !== "user" && !agents.some((x) => x.agent === a))
    agents.push({ agent: a, why: `закрыть gap ${g.id}: ${g.desc}` })
}

const unix_style = {
  composition: "pipes (stage_a && stage_b)",
  one_job_per_function: true,
  idempotent: true,
  dry_run: true,
  text_streams: "stdout — данные, stderr — логи",
}

const heuristic = {
  pipeline_type,
  complexity: { score, level },
  agents, unix_style,
  confidence: gaps.length ? 0.7 : 0.85,
  reason: `pipeline=${pipeline_type}, gaps=${gaps.length}, deploy=${target.deploy || "none"}`,
  provider: "heuristic", _reads: 1,
}

// Jev primary если настроен
const jevUrl = process.env.JEV_API_URL
const jevKey = process.env.JEV_API_KEY || process.env.OPENROUTER_API_KEY
if (jevUrl && jevKey) {
  try {
    const res = await fetch(jevUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${jevKey}` },
      body: JSON.stringify({ task: { title, desc, survey, target, gaps }, classify: "cicd" }),
    })
    if (res.ok) {
      const j = await res.json()
      if (j.pipeline_type && ["ci-gate", "build-push", "deploy", "full"].includes(j.pipeline_type)) {
        const conf = j.confidence ?? 0.85
        if (conf >= 0.5) {
          console.log(JSON.stringify({
            pipeline_type: j.pipeline_type,
            complexity: j.complexity || heuristic.complexity,
            agents: j.agents || agents, unix_style,
            confidence: conf, reason: j.reason || "jev", provider: "jev", _reads: 1,
          }))
          process.exit(0)
        }
      }
    }
  } catch { }
}

console.log(JSON.stringify(heuristic))
