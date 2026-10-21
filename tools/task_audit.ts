import { resolveScript } from "./_resolve.ts"
export default {
  description: "Read-only аудит Trello-доски (JSON для ИИ). Обёртка над scripts/task-manager/audit.sh. Вернёт {board,totals,lists,overdue,blocked} — просрочки и Blocked by: уже посчитаны скриптом.",
  input: {
    type: "object",
    properties: {
      board: { type: "string", description: "Точное имя доски, default BOARD из .devbox-project" },
      tag: { type: "string", description: "Метка проекта, default NAME из .devbox-project" },
      all: { type: "boolean", description: "Без фильтра по метке — все карточки доски" },
      limit: { type: "number", description: "Макс. карточек на лист (default 50)" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { board?: string; tag?: string; all?: boolean; limit?: number }
    const { root, script } = resolveScript("task-manager/audit.sh", context)
    const parts = ["bash", script]
    if (args.board) parts.push("--board", args.board)
    if (args.tag) parts.push("--tag", args.tag)
    if (args.all) parts.push("--all")
    if (args.limit !== undefined) parts.push("--limit", String(args.limit))
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error(err || `task_audit failed ${proc.exitCode}`)
    const text = out.trim() || err.trim()
    return { content: text }
  },
}
