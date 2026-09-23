// @ts-nocheck
import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Классификатор task-manager: отличает 'завести задачу' (create) от 'объясни задачу' (explain) и 'аудит/статус' (audit). Возвращает {intent, confidence, reason, provider}. Используется task-manager перед делегированием к сабагентам, чтобы не путать explain vs create.",
  args: {
    text: tool.schema.string().describe("Текст пользователя целиком (сообщение)"),
    title: tool.schema.string().optional().describe("Опционально: выделенный заголовок задачи"),
  },
  async execute(args, context) {
    const text = (args.text || args.title || "").trim()
    const lower = text.toLowerCase()

    // Сильные маркеры create
    const createRe = /(заведи|создай|создать|новая задача|new task|завести карточку|создать карточку|добавь задачу|создай задачу|заведи задачу|\/new-task)/i
    const explainRe = /(объясни|поясни|что\s+(это\s+)?(за\s+)?(задача|карточка)|расскажи про|что значит|что делает|зачем.*задача|статус задачи|где.*задача|explain|what.*task|describe.*task)/i
    const auditRe = /(аудит|статус задач|что выполнено|что в работе|проверь доску|audit|board status)/i
    const moveRe = /(перемести|перенеси|move.*to|переведи.*в.*(лист|done|doing))/i

    let intent = "create"
    let reason = "по умолчанию — создание"
    let confidence = 0.55

    const isCreate = createRe.test(lower)
    const isExplain = explainRe.test(lower)
    const isAudit = auditRe.test(lower)
    const isMove = moveRe.test(lower)

    // Приоритет: если есть вопросительный маркер + explain — explain, даже если есть слово задача
    if (isExplain && !isCreate) { intent = "explain"; reason = "вопрос о задаче: объясни/что это/расскажи"; confidence = 0.9 }
    else if (isExplain && isCreate) {
      // конфликт: "заведи задачу и объясни" — считаем create если глагол заведи раньше
      const createIdx = lower.search(createRe)
      const explainIdx = lower.search(explainRe)
      if (explainIdx < createIdx && /\?/.test(text)) { intent = "explain"; reason = "сначала вопрос, затем создание — трактуем как explain"; confidence = 0.65 }
      else { intent = "create"; reason = "императив заведи/создай перекрывает вопрос"; confidence = 0.7 }
    }
    else if (isAudit) { intent = "audit"; reason = "запрос аудита/статуса доски"; confidence = 0.85 }
    else if (isMove) { intent = "move"; reason = "перемещение карточки"; confidence = 0.85 }
    else if (isCreate) { intent = "create"; reason = "императив заведи/создай/новая задача"; confidence = 0.85 }
    else if (/\?/.test(text) && /(задач|карточк|trello)/i.test(lower)) { intent = "explain"; reason = "вопрос с ? про задачу/карточку"; confidence = 0.75 }
    else if (/(помоги|как|что нужно|зачем)/i.test(lower) && /(задач|карточк)/i.test(lower)) { intent = "explain"; reason = "просьба пояснить задачу"; confidence = 0.7 }

    // Jev primary если настроен
    const jevUrl = process.env.JEV_API_URL
    const jevKey = process.env.JEV_API_KEY || process.env.OPENROUTER_API_KEY
    if (jevUrl && jevKey) {
      try {
        const res = await fetch(jevUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${jevKey}` },
          body: JSON.stringify({ text, classify: "task-manager", candidates: ["create","explain","audit","move"] }),
        })
        if (res.ok) {
          const j = await res.json()
          if (j.intent && ["create","explain","audit","move"].includes(j.intent)) {
            const conf = j.confidence ?? 0.85
            if (conf >= 0.5) return JSON.stringify({ intent: j.intent, confidence: conf, reason: j.reason ?? "jev", provider: "jev", fallback: { intent, confidence, reason } }, null, 2)
          }
        }
      } catch {}
    }

    return JSON.stringify({ intent, confidence, reason, provider: "heuristic" }, null, 2)
  },
})
