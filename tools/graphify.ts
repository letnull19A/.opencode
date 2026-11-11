import { resolveScript } from "./_resolve.ts"
export default {
  description: "Граф зависимостей файлов (для evol-plan complexity). Обёртка над scripts/graphify/run.sh: index | search --query <q> [--mode file|content|both] [--limit N] | status. Всегда JSON.",
  input: {
    type: "object",
    properties: {
      command: { type: "string", enum: ["index", "search", "status"], description: "Команда скрипта (index — переиндексация, search — поиск, status — состояние индекса)" },
      query: { type: "string", description: "Строка поиска (обязательна для search)" },
      mode: { type: "string", enum: ["file", "content", "both"], description: "Область поиска (default both)" },
      limit: { type: "number", description: "Макс. результатов (default 50)" },
      force: { type: "boolean", description: "Для index — переиндексация принудительно" },
      root: { type: "string", description: "Корень индексации (default — корень consumer-репо)" },
    },
    required: ["command"],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { command: string; query?: string; mode?: string; limit?: number; force?: boolean; root?: string }
    const { root, script } = resolveScript("graphify/run.sh", context)
    const parts = ["bash", script, args.command]
    if (args.query) parts.push("--query", args.query)
    if (args.mode) parts.push("--mode", args.mode)
    if (args.limit !== undefined) parts.push("--limit", String(args.limit))
    if (args.force) parts.push("--force")
    if (args.root) parts.push("--root", args.root)
    parts.push("--json")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error((out + "\n" + err).trim() || `graphify ${args.command} failed ${proc.exitCode}`)
    const text = out.trim() || err.trim()
    return { content: text }
  },
}
