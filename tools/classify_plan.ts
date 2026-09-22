// @ts-nocheck
import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Классификатор планирования: выбирает подход — new-module (с нуля), update (доработка), decompose (разбиение) и нужен ли react-architect. Принимает заголовок/описание задачи, пробует Jev → heuristic. Возвращает {approach, needs_react, confidence, reason, provider}.",
  args: {
    title: tool.schema.string().optional().describe("Заголовок задачи"),
    desc: tool.schema.string().optional().describe("Описание задачи"),
    has_code: tool.schema.boolean().optional().describe("Есть ли уже код модуля в репо"),
  },
  async execute(args, context) {
    const title = args.title ?? ""
    const desc = args.desc ?? ""
    const text = `${title} ${desc}`.toLowerCase()
    const hasCode = args.has_code ?? false

    // Heuristic for approach
    const isReact = /(react|компонент|ui|frontend|jsx|tsx|hook|props)/i.test(text)
    let approach = "update"
    let reason = "доработка существующего"
    if (/(создать.*модул|новый модул|с нуля|new module|from scratch)/i.test(text)) {
      approach = "new-module"
      reason = "создание модуля с нуля"
    } else if (/(декомпоз|разбить|разделить|большой модул)/i.test(text)) {
      approach = "decompose"
      reason = "декомпозиция большого модуля"
    } else if (/(внедр|добавить функц|расшир|улучш|доработ)/i.test(text)) {
      approach = "update"
      reason = "внедрение нового функционала в существующее"
    } else if (!hasCode) {
      approach = "new-module"
      reason = "кода нет — новый модуль"
    }

    // Jev primary if configured
    const jevUrl = process.env.JEV_API_URL
    const jevKey = process.env.JEV_API_KEY || process.env.OPENROUTER_API_KEY
    if (jevUrl && jevKey) {
      try {
        const res = await fetch(jevUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${jevKey}` },
          body: JSON.stringify({ task: { title, desc, has_code: hasCode }, classify: "plan" }),
        })
        if (res.ok) {
          const j = await res.json()
          if (j.approach === "new-module" || j.approach === "update" || j.approach === "decompose") {
            const conf = j.confidence ?? 0.85
            if (conf >= 0.5) return JSON.stringify({ approach: j.approach, needs_react: j.needs_react ?? isReact, confidence: conf, reason: j.reason ?? "jev", provider: "jev", has_code: hasCode }, null, 2)
          }
        }
      } catch {}
    }

    const needsReact = isReact
    const confidence = hasCode || /(создать|новый|декомпоз)/i.test(text) ? 0.8 : 0.6
    return JSON.stringify({ approach, needs_react: needsReact, confidence, reason, provider: "heuristic", has_code: hasCode }, null, 2)
  },
})
