import path from "path"
export default {
  description: "Создание Trello-карточки с меткой проекта NAME. Обёртка над scripts/task-manager/create.sh. Требует title, берёт BOARD/LIST из .devbox-project если не переданы.",
  input: {
    type: "object",
    properties: {
      title: { type: "string", description: "Заголовок карточки, императив до ~80 символов, без точки" },
      board: { type: "string", description: "Точное имя доски, default BOARD из .devbox-project" },
      list: { type: "string", description: "Точное имя листа, default LIST из .devbox-project" },
      desc: { type: "string", description: "Описание по шаблону ## Контекст / ## Что сделать / ## Критерии / ## Связи" },
      color: { type: "string", description: "Цвет метки: green/yellow/orange/red/purple/blue/sky/lime/pink/black (default green)" },
      save_defaults: { type: "boolean", description: "Запомнить BOARD/LIST в .devbox-project" },
    },
    required: ["title"],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { title: string; board?: string; list?: string; desc?: string; color?: string; save_defaults?: boolean }
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-manager/create.sh")
    const parts = ["bash", script, "--title", args.title]
    if (args.board) parts.push("--board", args.board)
    if (args.list) parts.push("--list", args.list)
    if (args.desc) parts.push("--desc", args.desc)
    if (args.color) parts.push("--color", args.color)
    if (args.save_defaults) parts.push("--save-defaults")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0) throw new Error((out + "\n" + err).trim() || `create failed ${proc.exitCode}`)
    const text = (out + "\n" + err).trim()
    return { content: text }
  },
}
