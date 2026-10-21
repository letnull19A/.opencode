import path from "path"
export default {
  description: "Граф зависимостей файлов (для evol-plan complexity). Обёртка над scripts/graphify/run.sh — files/cards/deps/fan-out.",
  input: {
    type: "object",
    properties: {
      pattern: { type: "string", description: "Глоб файлов, напр. src/**/*.ts" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { pattern?: string }
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/graphify/run.sh")
    const parts = ["bash", script]
    if (args.pattern) parts.push(args.pattern)
    parts.push("--json")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error((out + "\n" + err).trim() || `graphify failed ${proc.exitCode}`)
    const text = out.trim() || err.trim()
    return { content: text }
  },
}
