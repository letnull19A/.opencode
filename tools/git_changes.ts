// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"

export default tool({
  description: "Git-изменения в LLM-формате: dirty tree + последние коммиты с Trello-трейлерами. Обёртка над scripts/git-changes/run.sh. Вернёт JSON {branch,dirty,log,by_card} — чтобы аудит не пропустил незакоммиченное.",
  args: {
    limit: tool.schema.number().optional().describe("Сколько коммитов показать (default 20, кап 100)"),
    since: tool.schema.string().optional().describe("Git since, напр. '2 weeks ago' или '2026-09-01'"),
    branch: tool.schema.string().optional().describe("Ветка для log, default текущая"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/git-changes/run.sh")
    const parts = ["bash", script]
    if (args.limit !== undefined) parts.push("--limit", String(args.limit))
    if (args.since) parts.push("--since", args.since)
    if (args.branch) parts.push("--branch", args.branch)
    parts.push("--json")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error(err || `git_changes failed ${proc.exitCode}`)
    return out.trim() || err.trim()
  },
})
