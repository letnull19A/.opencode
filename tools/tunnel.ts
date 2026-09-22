// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"

export default tool({
  description: "Управление preview-тоннелями (ngrok/loca.lt) для dev-сервера. Обёртка над scripts/tunnel/run.sh — create/status/url/restart/kill. Возвращает PREVIEW_URL/PROVIDER/PUBLIC_IP.",
  args: {
    action: tool.schema.enum(["start", "status", "url", "restart", "kill"]).describe("Действие тоннеля"),
    port: tool.schema.number().optional().describe("Порт dev-сервера (vite 5173, next 3000)"),
    name: tool.schema.string().optional().describe("Имя тоннеля (default default) для нескольких тоннелей"),
    ttl: tool.schema.number().optional().describe("TTL секунд, default 3600"),
    provider: tool.schema.enum(["auto", "ngrok", "localtunnel"]).optional().describe("Провайдер: auto (ngrok если есть NGROK_AUTHTOKEN, иначе loca.lt)"),
    all: tool.schema.boolean().optional().describe("Для kill --all"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/tunnel/run.sh")
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
    return combined
  },
})
