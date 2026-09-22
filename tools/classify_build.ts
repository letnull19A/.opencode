// @ts-nocheck
import { tool } from "@opencode-ai/plugin"

// Классификатор для router: выбирает build-fast vs build-smart.
// Unix-tool: одна задача — классификация. Поддерживает несколько провайдеров
// с fallback: Jev (primary, если доступен) → opencode → эвристика.
// Jev — внешний специализированный классификатор (напр. openrouter/jev или http api).
// Если Jev недоступен / не настроен, классификатор не падает — откатывается на эвристику
// по complexity/risk (как в router.md) и возвращает детерминированный выбор.
export default tool({
  description: "Классификатор build: выбирает build-fast (low) или build-smart (medium/high) для задачи. Принимает complexity/risk от evol-plan или сырые поля задачи, пробует Jev → fallback на opencode → эвристику. Возвращает JSON {builder, confidence, reason, provider}.",
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

    // 1) Попытка Jev — внешний провайдер. URL и ключ — через env, чтобы не коммитить.
    // Ожидается: $JEV_API_URL, $JEV_API_KEY (или $OPENROUTER_API_KEY для openrouter/jev).
    // Если не заданы — пропускаем без ошибки.
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
          // ожидается {builder: "build-fast"|"build-smart", confidence: 0-1, reason: "..."}
          if (j.builder === "build-fast" || j.builder === "build-smart") {
            return JSON.stringify({ builder: j.builder, confidence: j.confidence ?? 0.85, reason: j.reason ?? "jev", provider: "jev", input }, null, 2)
          }
        }
      } catch {}
    }

    // 2) Fallback: opencode модель как классификатор — детерминированная эвристика,
    // повторяющая логику router.md, но вынесенная в tool (не в промпт).
    // Это не вызов LLM, а быстрый rule-based выбор — дешевле и стабильнее.
    // Если позже появится opencode-классификатор как tool с LLM, его можно воткнуть здесь.
    const isHighRisk = input.risk_level === "high" || (input.risk_score ?? 0) >= 6
    if (isHighRisk) {
      return JSON.stringify({ builder: "build-smart", confidence: 0.92, reason: "risk high → spec-first", provider: "heuristic", input }, null, 2)
    }
    const isLow = input.level === "low" && input.risk_level === "low" && (input.files ?? 0) <= 2 && input.type === "add" && (input.deps ?? 0) === 0
    if (isLow) {
      return JSON.stringify({ builder: "build-fast", confidence: 0.88, reason: "low complexity, low risk, ≤2 files, type add, no deps", provider: "heuristic", input }, null, 2)
    }
    // пограничный medium с 1 карточкой и low risk — отдаём fast с hint (как в router.md)
    if (input.level === "medium" && input.risk_level === "low" && (input.files ?? 0) <= 2) {
      return JSON.stringify({ builder: "build-fast", confidence: 0.6, reason: "borderline medium → fast with hint check API", provider: "heuristic", input, hint: "быстро, но проверь API" }, null, 2)
    }
    return JSON.stringify({ builder: "build-smart", confidence: 0.75, reason: "medium/high complexity or deps/type update/decompose", provider: "heuristic", input }, null, 2)
  },
})
