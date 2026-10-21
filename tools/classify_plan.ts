export default {
  description: "Классификатор планирования: выбирает подход — new-module (с нуля), update (доработка), decompose (разбиение) и нужен ли react-architect. Принимает заголовок/описание задачи, heuristic. Возвращает {approach, needs_react, confidence, reason, provider}.",
  input: {
    type: "object",
    properties: {
      title: { type: "string", description: "Заголовок задачи" },
      desc: { type: "string", description: "Описание задачи" },
      has_code: { type: "boolean", description: "Есть ли уже код модуля в репо" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, _context: unknown) {
    const args = (input ?? {}) as { title?: string; desc?: string; has_code?: boolean }
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

    const needsReact = isReact
    const confidence = hasCode || /(создать|новый|декомпоз)/i.test(text) ? 0.8 : 0.6
    const text_out = JSON.stringify({ approach, needs_react: needsReact, confidence, reason, provider: "heuristic", has_code: hasCode }, null, 2)
    return { content: text_out }
  },
}
