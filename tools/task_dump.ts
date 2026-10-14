// @ts-nocheck
import { z } from "zod"
import path from "path"
export default {
  description: "Дамп карточек доски (read-only, JSON). Обёртка над scripts/task-manager/dump.sh — без фильтра, для сверки shortUrl с git трейлерами.",
  args: {
    board: z.string().optional().describe("Точное имя доски, default BOARD из .devbox-project"),
    tag: z.string().optional().describe("Метка проекта, default NAME"),
    all: z.boolean().optional().describe("Без фильтра — все карточки доски"),
    limit: z.number().optional().describe("Макс. карточек (default 50)"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-manager/dump.sh")
    const parts = ["bash", script]
    if (args.board) parts.push("--board", args.board)
    if (args.tag) parts.push("--tag", args.tag)
    if (args.all) parts.push("--all")
    if (args.limit !== undefined) parts.push("--limit", String(args.limit))
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error((err || out).trim() || `dump failed ${proc.exitCode}`)
    return out.trim() || err.trim()
  },
}
