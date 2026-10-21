import { resolveScript } from "./_resolve.ts"
export default {
  description: "Чек-листы Trello-карточки (подзадачи). Обёртка над scripts/task-manager/checklist.sh. Действия: show/create/add-item/complete/complete-all/uncomplete.",
  input: {
    type: "object",
    properties: {
      id: { type: "string", description: "ID карточки" },
      url: { type: "string", description: "URL карточки" },
      card: { type: "string", description: "Точное имя карточки" },
      from_board: { type: "string", description: "Сузить поиск по доске при --card" },
      list: { type: "string", description: "Точное имя чек-листа (если на карточке один — можно опустить)" },
      show: { type: "boolean", description: "Показать чек-листы JSON" },
      create: { type: "string", description: "Создать чек-лист с именем" },
      items: { type: "string", description: "Пункты через ; для --create" },
      add_item: { type: "string", description: "Добавить пункт в чек-лист" },
      complete: { type: "string", description: "Отметить пункт как выполненный (точное имя)" },
      complete_all: { type: "boolean", description: "Отметить все пункты чек-листа" },
      uncomplete: { type: "string", description: "Снять отметку с пункта" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { id?: string; url?: string; card?: string; from_board?: string; list?: string; show?: boolean; create?: string; items?: string; add_item?: string; complete?: string; complete_all?: boolean; uncomplete?: string }
    const { root, script } = resolveScript("task-manager/checklist.sh", context)
    const parts = ["bash", script]
    if (args.id) parts.push("--id", args.id)
    if (args.url) parts.push("--url", args.url)
    if (args.card) parts.push("--card", args.card)
    if (args.from_board) parts.push("--from-board", args.from_board)
    if (args.list) parts.push("--list", args.list)
    if (args.show) parts.push("--show")
    if (args.create) parts.push("--create", args.create)
    if (args.items) parts.push("--items", args.items)
    if (args.add_item) parts.push("--add-item", args.add_item)
    if (args.complete) parts.push("--complete", args.complete)
    if (args.complete_all) parts.push("--complete-all")
    if (args.uncomplete) parts.push("--uncomplete", args.uncomplete)
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0) throw new Error((out + "\n" + err).trim() || `checklist failed ${proc.exitCode}`)
    const text = (out + "\n" + err).trim()
    return { content: text }
  },
}
