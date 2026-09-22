// @ts-nocheck
import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Классификатор build: выбирает build-fast (low), build-smart (medium/high) или build (default fallback) для задачи. Принимает complexity/risk от evol-plan или сырые поля задачи, пробует Jev → fallback на эвристику → build по умолчанию. Возвращает JSON {builder, confidence, reason, provider}.",
  args: {
    title: tool.schema.string().optional().describe("Заголовок задачи / карточки Trello"),
    desc: tool.schema.string().optional().describe("Описание задачи (## Что сделать / Критерии)"),
    level: tool.schema.enum(["low", "medium", "high"]).optional().describe("Уровень сложности из evol-plan"),
    score: tool.schema.number().optional().describe("Score сложности 0-20"),
    files: tool.schema.number().optional().describe("Кол-во файлов в задаче"),
    deps: tool.schema.number().optional().describe("Кол-во зависимостей"),
    type: tool.schema.enum(["add", "update", "delete", "decompose"]).optional().describe("Тип изменения"),
    unknowns: tool.schema.number().optional().describe("Неопределённость"),
    risk_level: tool.schema.enum(["low", "medium", "high"]).optional().describe("Уровень риска"),
    risk_score: tool.schema.number().optional().describe("Риск score 0-8"),
    risk_factors: tool.schema.array(tool.schema.string()).optional().describe("Факторы риска: breaking,data,security,external"),
  },
  async execute(args, context) {
    const hasTitle = !!(args.title && args.title.trim())
    const hasDesc = !!(args.desc && args.desc.trim())
    const hasLevel = !!args.level
    const hasScore = args.score !== undefined
    const hasFiles = args.files !== undefined
    const input = {
      title: args.title ?? "",
      desc: args.desc ?? "",
      level: args.level ?? "medium",
      score: args.score ?? 5,
      files: args.files ?? 1,
      deps: args.deps ?? 0,
      type: args.type ?? "update",
      unknowns: args.unknowns ?? 0,
      risk_level: args.risk_level ?? "low",
      risk_score: args.risk_score ?? 0,
      risk_factors: args.risk_factors ?? [],
    }

    const isInsufficient = !hasTitle && !hasDesc && !hasLevel && !hasScore && !hasFiles && (args.unknowns ?? 0) >= 2

    const jevUrl = process.env.JEV_API_URL
    const jevKey = process.env.JEV_API_KEY || process.env.OPENROUTER_API_KEY
    if (jevUrl && jevKey) {
      try {
        const res = await fetch(jevUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${jevKey}` },
          body: JSON.stringify({ task: input }),
        })
        if (res.ok) {
          const j = await res.json()
          if (j.builder === "build-fast" || j.builder === "build-smart" || j.builder === "build") {
            const conf = j.confidence ?? 0.85
            if (conf >= 0.5) return JSON.stringify({ builder: j.builder, confidence: conf, reason: j.reason ?? "jev", provider: "jev", input }, null, 2)
          }
          if (j.builder === "unknown" || (j.confidence !== undefined && j.confidence < 0.5)) {
            // Jev не смог определить — откат к эвристике/build
          } else if (j.builder) {
            return JSON.stringify({ builder: j.builder, confidence: j.confidence ?? 0.85, reason: j.reason ?? "jev", provider: "jev", input }, null, 2)
          }
        }
      } catch {}
    }

    if (isInsufficient) {
      return JSON.stringify({ builder: "build", confidence: 0.4, reason: "недостаточно данных для классификации — fallback к build по умолчанию", provider: "heuristic", input }, null, 2)
    }

    const isHighRisk = input.risk_level === "high" || (input.risk_score ?? 0) >= 6
    if (isHighRisk) {
      return JSON.stringify({ builder: "build-smart", confidence: 0.92, reason: "risk high → spec-first", provider: "heuristic", input }, null, 2)
    }
    const isLow = input.level === "low" && input.risk_level === "low" && (input.files ?? 0) <= 2 && input.type === "add" && (input.deps ?? 0) === 0
    if (isLow) {
      return JSON.stringify({ builder: "build-fast", confidence: 0.88, reason: "low complexity, low risk, ≤2 files, type add, no deps", provider: "heuristic", input }, null, 2)
    }
    if (input.level === "medium" && input.risk_level === "low" && (input.files ?? 0) <= 2) {
      if ((input.unknowns ?? 0) >= 2) {
        return JSON.stringify({ builder: "build", confidence: 0.45, reason: "borderline medium с высокой неопределённостью — fallback к build", provider: "heuristic", input }, null, 2)
      }
      return JSON.stringify({ builder: "build-fast", confidence: 0.6, reason: "borderline medium → fast with hint check API", provider: "heuristic", input, hint: "быстро, но проверь API" }, null, 2)
    }
    if ((input.unknowns ?? 0) >= 3) {
      return JSON.stringify({ builder: "build", confidence: 0.4, reason: "высокая неопределённость — fallback к build по умолчанию", provider: "heuristic", input }, null, 2)
    }
    return JSON.stringify({ builder: "build-smart", confidence: 0.75, reason: "medium/high complexity or deps/type update/decompose", provider: "heuristic", input }, null, 2)
  },
})
