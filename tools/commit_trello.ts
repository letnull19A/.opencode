// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"

export default tool({
  description: "Поиск связи коммитов ↔ Trello-карточек по трейлерам Trello:/Closes:. Обёртка над scripts/commit-trello/run.sh. Парсит git log без Trello API.",
  args: {
    card: tool.schema.string().optional().describe("URL/shortLink/id карточки Trello (https://trello.com/c/<SHORT> или SHORT)"),
    commit: tool.schema.string().optional().describe("Хеш коммита (7+ символов)"),
    all: tool.schema.boolean().optional().describe("Все коммиты с Trello/Closes"),
    limit: tool.schema.number().optional().describe("Лимит коммитов (default 50)"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/commit-trello/run.sh")
    const parts = ["bash", script]
    if (args.card) parts.push("--card", args.card)
    if (args.commit) parts.push("--commit", args.commit)
    if (args.all) parts.push("--all")
    if (args.limit !== undefined) parts.push("--limit", String(args.limit))
    parts.push("--json")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error(err || `commit_trello failed ${proc.exitCode}`)
    return out.trim() || err.trim()
  },
})
