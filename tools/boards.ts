// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"
export default tool({
  description: "Список открытых Trello-досок (id + name). Обёртка над scripts/task-manager/boards.sh — только чтение, без гаданий.",
  args: {},
  async execute(_, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-manager/boards.sh")
    const proc = Bun.spawn(["bash", script], { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim()) throw new Error(err || `boards failed ${proc.exitCode}`)
    return out.trim() || err.trim()
  },
})
