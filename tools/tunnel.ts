import { resolveScript } from "./_resolve.ts"
export default {
  description: "Управление preview-тоннелями (ngrok/loca.lt) для dev-сервера. Обёртка над scripts/tunnel/run.sh — create/status/url/restart/kill. Возвращает PREVIEW_URL/PROVIDER/PUBLIC_IP.",
  input: {
    type: "object",
    properties: {
      action: { type: "string", enum: ["start", "status", "url", "restart", "kill"], description: "Действие тоннеля" },
      port: { type: "number", description: "Порт dev-сервера (vite 5173, next 3000)" },
      name: { type: "string", description: "Имя тоннеля (default default) для нескольких тоннелей" },
      ttl: { type: "number", description: "TTL секунд, default 3600" },
      provider: { type: "string", enum: ["auto", "ngrok", "localtunnel"], description: "Провайдер: auto (ngrok если есть NGROK_AUTHTOKEN, иначе loca.lt)" },
      all: { type: "boolean", description: "Для kill --all" },
    },
    required: ["action"],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { action: string; port?: number; name?: string; ttl?: number; provider?: string; all?: boolean }
    const { root, script } = resolveScript("tunnel/run.sh", context)
    const parts = ["bash", script, args.action]
    if (args.port !== undefined) parts.push("--port", String(args.port))
    if (args.name) parts.push("--name", args.name)
    if (args.ttl !== undefined) parts.push("--ttl", String(args.ttl))
    if (args.provider) parts.push("--provider", args.provider)
    if (args.all) parts.push("--all")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    const combined = (out + "\n" + err).trim()
    if (proc.exitCode !== 0 && !combined) throw new Error(`tunnel ${args.action} failed ${proc.exitCode}`)
    if (proc.exitCode !== 0 && args.action !== "status" && args.action !== "url") throw new Error(combined || `tunnel ${args.action} failed ${proc.exitCode}`)
    return { content: combined }
  },
}
