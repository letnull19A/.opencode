// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"
export default tool({
  description: "Инициализация тега проекта .devbox-project (NAME=owner/repo, BOARD/LIST дефолты). Обёртка над scripts/task-manager/init.sh — тег из git remote.",
  args: {
    name: tool.schema.string().optional().describe("Явный тег owner/repo (перекрывает автовывод из git remote)"),
    force: tool.schema.boolean().optional().describe("Перезаписать .devbox-project, сохранив BOARD/LIST"),
    remote: tool.schema.string().optional().describe("Git remote для автовывода (default origin)"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-manager/init.sh")
    const parts = ["bash", script]
    if (args.name) parts.push("--name", args.name)
    if (args.force) parts.push("--force")
    if (args.remote) parts.push("--remote", args.remote)
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0) throw new Error((out + "\n" + err).trim() || `init failed ${proc.exitCode}`)
    return (out + "\n" + err).trim()
  },
})
