import path from "path"
export default {
  description: "Инициализация тега проекта .devbox-project (NAME=owner/repo, BOARD/LIST дефолты). Обёртка над scripts/task-manager/init.sh — тег из git remote.",
  input: {
    type: "object",
    properties: {
      name: { type: "string", description: "Явный тег owner/repo (перекрывает автовывод из git remote)" },
      force: { type: "boolean", description: "Перезаписать .devbox-project, сохранив BOARD/LIST" },
      remote: { type: "string", description: "Git remote для автовывода (default origin)" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { name?: string; force?: boolean; remote?: string }
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
    const text = (out + "\n" + err).trim()
    return { content: text }
  },
}
