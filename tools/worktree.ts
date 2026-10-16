// @ts-nocheck
import { z } from "zod"
import path from "path"
export default {
  description: "Worktree-менеджер (параллельная разработка). Обёртка над scripts/worktree/run.sh: create/list/status/remove/done/prune. done — завершение жизненного цикла (PR-гейт MERGED → удалить worktree → подтянуть base).",
  args: {
    command: z.enum(["create", "list", "status", "remove", "done", "prune"]).describe("Команда worktree"),
    name: z.string().optional().describe("Имя worktree / ветки"),
    branch: z.string().optional().describe("Ветка для create (или переопределение ветки для done)"),
    base: z.string().optional().describe("Целевая ветка для done-синка (default main)"),
    from: z.string().optional().describe("Откуда ветвить"),
    remote: z.string().optional().describe("Git remote для done (default origin)"),
    keep_branch: z.boolean().optional().describe("Для done — не удалять локальную ветку"),
    json: z.boolean().optional().describe("Вывод JSON"),
    force: z.boolean().optional().describe("Force для remove/done"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/worktree/run.sh")
    const parts = ["bash", script, args.command]
    if (args.name) parts.push("--name", args.name)
    if (args.branch) parts.push("--branch", args.branch)
    if (args.base) parts.push("--base", args.base)
    if (args.from) parts.push("--from", args.from)
    if (args.remote) parts.push("--remote", args.remote)
    if (args.keep_branch) parts.push("--keep-branch")
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
