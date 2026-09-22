// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"
export default tool({
  description: "Поиск семантических дублей Trello-задач. Обёртка над scripts/task-manager/find_duplicates.sh — возвращает {count, duplicates:[{name,shortUrl,similarity,reason}]}, threshold 0.65 для автоблока.",
  args: {
    title: tool.schema.string().optional().describe("Заголовок для проверки дубля"),
    desc: tool.schema.string().optional().describe("Описание для проверки"),
    board: tool.schema.string().optional().describe("Точное имя доски"),
    json: tool.schema.boolean().optional().describe("Вывод JSON (default)"),
    threshold: tool.schema.number().optional().describe("Порог similarity 0-1 (default 0.65)"),
    all: tool.schema.boolean().optional().describe("Аудит всех дублей доски (пары)"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-manager/find_duplicates.sh")
    const parts = ["bash", script]
    if (args.title) parts.push("--title", args.title)
    if (args.desc) parts.push("--desc", args.desc)
    if (args.board) parts.push("--board", args.board)
    if (args.json ?? true) parts.push("--json")
    if (args.threshold !== undefined) parts.push("--threshold", String(args.threshold))
    if (args.all) parts.push("--all")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error((err || out).trim() || `find_duplicates failed ${proc.exitCode}`)
    return out.trim() || err.trim()
  },
})
