import { resolveScript } from "./_resolve.ts"
export default {
  description: "Worktree-менеджер (параллельная разработка). Обёртка над scripts/worktree/run.sh: create/list/status/remove/done/prune. done — завершение жизненного цикла (PR-гейт MERGED → удалить worktree → подтянуть base).",
  input: {
    type: "object",
    properties: {
      command: { type: "string", enum: ["create", "list", "status", "remove", "done", "prune"], description: "Команда worktree" },
      name: { type: "string", description: "Имя worktree / ветки" },
      branch: { type: "string", description: "Ветка для create (или переопределение ветки для done)" },
      base: { type: "string", description: "Целевая ветка для done-синка (default main)" },
      from: { type: "string", description: "Откуда ветвить" },
      remote: { type: "string", description: "Git remote для done (default origin)" },
      keep_branch: { type: "boolean", description: "Для done — не удалять локальную ветку" },
      json: { type: "boolean", description: "Вывод JSON" },
      force: { type: "boolean", description: "Force для remove/done" },
    },
    required: ["command"],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { command: string; name?: string; branch?: string; base?: string; from?: string; remote?: string; keep_branch?: boolean; json?: boolean; force?: boolean }
    const { root, script } = resolveScript("worktree/run.sh", context)
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
    const text = (out + "\n" + err).trim()
    return { content: text }
  },
}
