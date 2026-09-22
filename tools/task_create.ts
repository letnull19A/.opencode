// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"
export default tool({
  description: "Создание Trello-карточки с меткой проекта NAME. Обёртка над scripts/task-manager/create.sh. Требует title, берёт BOARD/LIST из .devbox-project если не переданы.",
  args: {
    title: tool.schema.string().describe("Заголовок карточки, императив до ~80 символов, без точки"),
    board: tool.schema.string().optional().describe("Точное имя доски, default BOARD из .devbox-project"),
    list: tool.schema.string().optional().describe("Точное имя листа, default LIST из .devbox-project"),
    desc: tool.schema.string().optional().describe("Описание по шаблону ## Контекст / ## Что сделать / ## Критерии / ## Связи"),
    color: tool.schema.string().optional().describe("Цвет метки: green/yellow/orange/red/purple/blue/sky/lime/pink/black (default green)"),
    save_defaults: tool.schema.boolean().optional().describe("Запомнить BOARD/LIST в .devbox-project"),
  },
  async execute(args, context) {
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
    return (out + "\n" + err).trim()
  },
})
