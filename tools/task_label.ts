// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"
export default tool({
  description: "Метки Trello (цветные label). Обёртка над scripts/task-manager/label.sh — создаёт/проверяет метку проекта.",
  args: {
    board: tool.schema.string().optional().describe("Точное имя доски, default BOARD из .devbox-project"),
    name: tool.schema.string().optional().describe("Имя метки, default NAME из .devbox-project"),
    color: tool.schema.string().optional().describe("Цвет: green/yellow/orange/red/purple/blue/sky/lime/pink/black и *_dark/*_light"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-manager/label.sh")
    const parts = ["bash", script]
    if (args.board) parts.push("--board", args.board)
    if (args.name) parts.push("--name", args.name)
    if (args.color) parts.push("--color", args.color)
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0) throw new Error((out + "\n" + err).trim() || `label failed ${proc.exitCode}`)
    return (out + "\n" + err).trim()
  },
})
