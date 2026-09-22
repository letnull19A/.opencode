// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"
export default tool({
  description: "Планировщик батчей Trello — лёгкие задачи пачкой + проверка has_fix. Обёртка над scripts/planner/run.sh → JSON {batches,singles,incomplete,heavy} для task-batch.",
  args: {
    board: tool.schema.string().optional().describe("Точное имя доски, default BOARD из .devbox-project"),
    tag: tool.schema.string().optional().describe("Метка проекта, default NAME"),
    all: tool.schema.boolean().optional().describe("Без фильтра — все карточки доски"),
    limit: tool.schema.number().optional().describe("Макс. карточек (default 100)"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/planner/run.sh")
    const parts = ["bash", script]
    if (args.board) parts.push("--board", args.board)
    if (args.tag) parts.push("--tag", args.tag)
    if (args.all) parts.push("--all")
    if (args.limit !== undefined) parts.push("--limit", String(args.limit))
    parts.push("--json")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error((err || out).trim() || `planner failed ${proc.exitCode}`)
    return out.trim() || err.trim()
  },
})
