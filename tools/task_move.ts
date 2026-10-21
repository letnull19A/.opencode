import { resolveScript } from "./_resolve.ts"
export default {
  description: "Перемещение Trello-карточки в другой лист/доску. Обёртка над scripts/task-manager/move.sh. Селектор карточки — ровно один: id/url/card.",
  input: {
    type: "object",
    properties: {
      id: { type: "string", description: "ID карточки" },
      url: { type: "string", description: "URL карточки https://trello.com/c/<SHORT>" },
      card: { type: "string", description: "Точное имя карточки (поиск по всем открытым доскам, уточни --from_board при дублях имён)" },
      from_board: { type: "string", description: "Сузить поиск по имени доски при --card" },
      list: { type: "string", description: "Целевой лист (точное имя)" },
      to_board: { type: "string", description: "Целевая доска (default текущая)" },
      pos: { type: "string", description: "Позиция: top|bottom|N" },
      dry_run: { type: "boolean", description: "Только показать план без PUT" },
    },
    required: ["list"],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { id?: string; url?: string; card?: string; from_board?: string; list: string; to_board?: string; pos?: string; dry_run?: boolean }
    const { root, script } = resolveScript("task-manager/move.sh", context)
    const parts = ["bash", script]
    if (args.id) parts.push("--id", args.id)
    if (args.url) parts.push("--url", args.url)
    if (args.card) parts.push("--card", args.card)
    if (args.from_board) parts.push("--from-board", args.from_board)
    parts.push("--list", args.list)
    if (args.to_board) parts.push("--to-board", args.to_board)
    if (args.pos) parts.push("--pos", args.pos)
    if (args.dry_run) parts.push("--dry-run")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0) throw new Error((out + "\n" + err).trim() || `move failed ${proc.exitCode}`)
    const text = (out + "\n" + err).trim()
    return { content: text }
  },
}
