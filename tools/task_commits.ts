// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"

export default tool({
  description: "Поиск коммитов по списку задач Trello (джойн задачи → коммиты с Trello:/Closes:). Unix-обёртка над scripts/task-commits/run.sh. stdout — JSON {tasks,commits,by_task,tasks_without_commits} для ИИ.",
  args: {
    board: tool.schema.string().optional().describe("Точное имя доски Trello, default BOARD из .devbox-project"),
    tag: tool.schema.string().optional().describe("Метка проекта NAME, default из .devbox-project"),
    all: tool.schema.boolean().optional().describe("Все карточки доски без фильтра по метке"),
    limit: tool.schema.number().optional().describe("Макс. карточек на лист (default 50)"),
    log_limit: tool.schema.number().optional().describe("Сколько последних коммитов сканировать (default 100, кап 500)"),
    tasks_file: tool.schema.string().optional().describe("Путь к JSON с задачами (audit.json/dump.json) вместо запроса к Trello"),
    tasks_json: tool.schema.string().optional().describe("Inline JSON с задачами (массив cards или audit)"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-commits/run.sh")
    const parts: string[] = ["bash", script]
    if (args.board) parts.push("--board", args.board)
    if (args.tag) parts.push("--tag", args.tag)
    if (args.all) parts.push("--all")
    if (args.limit !== undefined) parts.push("--limit", String(args.limit))
    if (args.log_limit !== undefined) parts.push("--log-limit", String(args.log_limit))
    if (args.tasks_file) parts.push("--tasks-file", args.tasks_file)
    if (args.tasks_json) parts.push("--tasks-json", args.tasks_json)
    parts.push("--json")
    // Bun.$ is available in opencode plugin runtime
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) {
      throw new Error(err || `task_commits failed code ${proc.exitCode}`)
    }
    return out.trim() || err.trim()
  },
})
