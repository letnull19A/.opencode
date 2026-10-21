import { resolveScript } from "./_resolve.ts"
export default {
  description: "Список открытых Trello-досок (id + name). Обёртка над scripts/task-manager/boards.sh — только чтение, без гаданий.",
  input: {
    type: "object",
    properties: {},
    required: [],
    additionalProperties: false,
  },
  async execute(_input: unknown, context: unknown) {
    const { root, script } = resolveScript("task-manager/boards.sh", context)
    const proc = Bun.spawn(["bash", script], { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim()) throw new Error(err || `boards failed ${proc.exitCode}`)
    const text = out.trim() || err.trim()
    return { content: text }
  },
}
