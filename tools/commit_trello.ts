import { resolveScript } from "./_resolve.ts"

export default {
  description: "Поиск связи коммитов ↔ Trello-карточек по трейлерам Trello:/Closes:. Обёртка над scripts/commit-trello/run.sh. Парсит git log без Trello API.",
  input: {
    type: "object",
    properties: {
      card: { type: "string", description: "URL/shortLink/id карточки Trello (https://trello.com/c/<SHORT> или SHORT)" },
      commit: { type: "string", description: "Хеш коммита (7+ символов)" },
      all: { type: "boolean", description: "Все коммиты с Trello/Closes" },
      limit: { type: "number", description: "Лимит коммитов (default 50)" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { card?: string; commit?: string; all?: boolean; limit?: number }
    const { root, script } = resolveScript("commit-trello/run.sh", context)
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
    const text = out.trim() || err.trim()
    return { content: text }
  },
}
