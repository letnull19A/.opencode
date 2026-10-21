import path from "path"
export default {
  description: "Проверка изменённых файлов (lint/typecheck/build). Обёртка над scripts/check/run.sh --json (только на diff, не весь проект).",
  input: {
    type: "object",
    properties: {
      json: { type: "boolean", description: "Вывод JSON" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { json?: boolean }
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/check/run.sh")
    const parts = ["bash", script]
    if (args.json ?? true) parts.push("--json")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error((out + "\n" + err).trim() || `check failed ${proc.exitCode}`)
    const text = out.trim() || err.trim()
    return { content: text }
  },
}
