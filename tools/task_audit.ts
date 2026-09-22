// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"

export default tool({
  description: "Read-only аудит Trello-доски (JSON для ИИ). Обёртка над scripts/task-manager/audit.sh. Вернёт {board,totals,lists,overdue,blocked} — просрочки и Blocked by: уже посчитаны скриптом.",
  args: {
    board: tool.schema.string().optional().describe("Точное имя доски, default BOARD из .devbox-project"),
    tag: tool.schema.string().optional().describe("Метка проекта, default NAME из .devbox-project"),
    all: tool.schema.boolean().optional().describe("Без фильтра по метке — все карточки доски"),
    limit: tool.schema.number().optional().describe("Макс. карточек на лист (default 50)"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-manager/audit.sh")
    const parts = ["bash", script]
    if (args.board) parts.push("--board", args.board)
    if (args.tag) parts.push("--tag", args.tag)
    if (args.all) parts.push("--all")
    if (args.limit !== undefined) parts.push("--limit", String(args.limit))
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error(err || `task_audit failed ${proc.exitCode}`)
    return out.trim() || err.trim()
  },
})
