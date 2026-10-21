import { resolveScript } from "./_resolve.ts"
export default {
  description: "Поиск семантических дублей Trello-задач. Обёртка над scripts/task-manager/find_duplicates.sh — возвращает {count, duplicates:[{name,shortUrl,similarity,reason}]}, threshold 0.65 для автоблока.",
  input: {
    type: "object",
    properties: {
      title: { type: "string", description: "Заголовок для проверки дубля" },
      desc: { type: "string", description: "Описание для проверки" },
      board: { type: "string", description: "Точное имя доски" },
      json: { type: "boolean", description: "Вывод JSON (default)" },
      threshold: { type: "number", description: "Порог similarity 0-1 (default 0.65)" },
      all: { type: "boolean", description: "Аудит всех дублей доски (пары)" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { title?: string; desc?: string; board?: string; json?: boolean; threshold?: number; all?: boolean }
    const { root, script } = resolveScript("task-manager/find_duplicates.sh", context)
    const parts = ["bash", script]
    if (args.title) parts.push("--title", args.title)
    if (args.desc) parts.push("--desc", args.desc)
    if (args.board) parts.push("--board", args.board)
    if (args.json ?? true) parts.push("--json")
    if (args.threshold !== undefined) parts.push("--threshold", String(args.threshold))
    if (args.all) parts.push("--all")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0 && !out.trim().startsWith("{")) throw new Error((err || out).trim() || `find_duplicates failed ${proc.exitCode}`)
    const text = out.trim() || err.trim()
    return { content: text }
  },
}
