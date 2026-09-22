// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"
export default tool({
  description: "Перемещение Trello-карточки в другой лист/доску. Обёртка над scripts/task-manager/move.sh. Селектор карточки — ровно один: id/url/card.",
  args: {
    id: tool.schema.string().optional().describe("ID карточки"),
    url: tool.schema.string().optional().describe("URL карточки https://trello.com/c/<SHORT>"),
    card: tool.schema.string().optional().describe("Точное имя карточки (поиск по всем открытым доскам, уточни --from_board при дублях)"),
    from_board: tool.schema.string().optional().describe("Сузить поиск по имени доски при --card"),
    list: tool.schema.string().describe("Целевой лист (точное имя)"),
    to_board: tool.schema.string().optional().describe("Целевая доска (default текущая)"),
    pos: tool.schema.string().optional().describe("Позиция: top|bottom|N"),
    dry_run: tool.schema.boolean().optional().describe("Только показать план без PUT"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-manager/move.sh")
    const parts = ["bash", script]
    if (args.id) parts.push("--id", args.id)
    if (args.url) parts.push("--url", args.url)
    if (args.card) parts.push("--card", args.card)
    if (args.from_board) parts.push("--from-board", args.from_board)
    parts.push("--list", args.list)
    if (args.to_board) parts.push("--to-board", args.to_board)
    if (args.pos) parts.push("--pos", args.pos)
    if (args.dry_run) parts.push("--dry-run")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0) throw new Error((out + "\n" + err).trim() || `move failed ${proc.exitCode}`)
    return (out + "\n" + err).trim()
  },
})
