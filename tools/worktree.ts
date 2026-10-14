// @ts-nocheck
import { z } from "zod"
import path from "path"
export default {
  description: "Worktree-менеджер (параллельная разработка). Обёртка над scripts/worktree/run.sh: create/list/status/remove/prune.",
  args: {
    command: z.enum(["create", "list", "status", "remove", "prune"]).describe("Команда worktree"),
    name: z.string().optional().describe("Имя worktree / ветки"),
    branch: z.string().optional().describe("Ветка для create"),
    base: z.string().optional().describe("Базовая ветка (default main)"),
    from: z.string().optional().describe("Откуда ветвить"),
    json: z.boolean().optional().describe("Вывод JSON"),
    force: z.boolean().optional().describe("Force для remove"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/worktree/run.sh")
    const parts = ["bash", script, args.command]
    if (args.name) parts.push("--name", args.name)
    if (args.branch) parts.push("--branch", args.branch)
    if (args.base) parts.push("--base", args.base)
    if (args.from) parts.push("--from", args.from)
    if (args.json) parts.push("--json")
    if (args.force) parts.push("--force")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0) throw new Error((out + "\n" + err).trim() || `worktree ${args.command} failed ${proc.exitCode}`)
    return (out + "\n" + err).trim()
  },
}
