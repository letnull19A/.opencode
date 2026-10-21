import path from "path"
export default {
  description: "Метки Trello (цветные label). Обёртка над scripts/task-manager/label.sh — создаёт/проверяет метку проекта.",
  input: {
    type: "object",
    properties: {
      board: { type: "string", description: "Точное имя доски, default BOARD из .devbox-project" },
      name: { type: "string", description: "Имя метки, default NAME из .devbox-project" },
      color: { type: "string", description: "Цвет: green/yellow/orange/red/purple/blue/sky/lime/pink/black и *_dark/*_light" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { board?: string; name?: string; color?: string }
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
    const text = (out + "\n" + err).trim()
    return { content: text }
  },
}
