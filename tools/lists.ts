import { resolveScript } from "./_resolve.ts"
export default {
  description: "Листы Trello-доски (id + name). Обёртка над scripts/task-manager/lists.sh --board. Только точные имена, без гаданий.",
  input: {
    type: "object",
    properties: {
      board: { type: "string", description: "Точное имя доски Trello (см. boards)" },
    },
    required: ["board"],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { board: string }
    const { root, script } = resolveScript("task-manager/lists.sh", context)
    const parts = ["bash", script, "--board", args.board]
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim()) throw new Error(err || `lists failed ${proc.exitCode}`)
    const text = out.trim() || err.trim()
    return { content: text }
  },
}
