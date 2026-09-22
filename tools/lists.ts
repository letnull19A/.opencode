// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"
export default tool({
  description: "Листы Trello-доски (id + name). Обёртка над scripts/task-manager/lists.sh --board. Только точные имена, без гаданий.",
  args: {
    board: tool.schema.string().describe("Точное имя доски Trello (см. boards)"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-manager/lists.sh")
    const parts = ["bash", script, "--board", args.board]
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim()) throw new Error(err || `lists failed ${proc.exitCode}`)
    return out.trim() || err.trim()
  },
})
