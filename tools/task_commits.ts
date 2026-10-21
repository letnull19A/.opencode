import { resolveScript } from "./_resolve.ts"
export default {
  description: "Поиск коммитов по списку задач Trello (джойн задачи → коммиты с Trello:/Closes:). Unix-обёртка над scripts/task-commits/run.sh. stdout — JSON {tasks,commits,by_task,tasks_without_commits} для ИИ.",
  input: {
    type: "object",
    properties: {
      board: { type: "string", description: "Точное имя доски Trello, default BOARD из .devbox-project" },
      tag: { type: "string", description: "Метка проекта NAME, default из .devbox-project" },
      all: { type: "boolean", description: "Все карточки доски без фильтра по метке" },
      limit: { type: "number", description: "Макс. карточек на лист (default 50)" },
      log_limit: { type: "number", description: "Сколько последних коммитов сканировать (default 100, кап 500)" },
      tasks_file: { type: "string", description: "Путь к JSON с задачами (audit.json/dump.json) вместо запроса к Trello" },
      tasks_json: { type: "string", description: "Inline JSON с задачами (массив cards или audit)" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { board?: string; tag?: string; all?: boolean; limit?: number; log_limit?: number; tasks_file?: string; tasks_json?: string }
    const { root, script } = resolveScript("task-commits/run.sh", context)
    const parts: string[] = ["bash", script]
    if (args.board) parts.push("--board", args.board)
    if (args.tag) parts.push("--tag", args.tag)
    if (args.all) parts.push("--all")
    if (args.limit !== undefined) parts.push("--limit", String(args.limit))
    if (args.log_limit !== undefined) parts.push("--log-limit", String(args.log_limit))
    if (args.tasks_file) parts.push("--tasks-file", args.tasks_file)
    if (args.tasks_json) parts.push("--tasks-json", args.tasks_json)
    parts.push("--json")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) {
      throw new Error(err || `task_commits failed code ${proc.exitCode}`)
    }
    const text = out.trim() || err.trim()
    return { content: text }
  },
}
