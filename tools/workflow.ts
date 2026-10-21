import path from "path"
export default {
  description: "Движок workflow'ов. Запускает декларации из workflows/<name>/workflow.json через workflows/engine.ts. Guardrails: allowlist/budget/BOARD-lock/preview. Триггер 'новая задача' → workflow new-task 0→1 (validate→classify→recon→plan→create). Триггер 'ci/cd скрипт' → workflow cicd-script (survey→target→classify→plan→scaffold→verify→report, UNIX-way bash для @devops).",
  input: {
    type: "object",
    properties: {
      name: { type: "string", description: "Имя workflow (папка в workflows/), default new-task" },
      input: { type: "string", description: "JSON строка {title,desc} или просто title. Минимум title 5 символов и desc ≥20 или шаблон ## Контекст/Что сделать/Критерии" },
      title: { type: "string", description: "Альтернатива input: заголовок задачи (императив до ~80)" },
      desc: { type: "string", description: "Описание по шаблону ## Контекст / ## Что сделать / ## Критерии приёмки" },
      dryRun: { type: "boolean", description: "true = preview без мутаций Trello (default true если не указан)" },
      json: { type: "boolean", description: "Вывод JSON" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { name?: string; input?: string; title?: string; desc?: string; dryRun?: boolean; json?: boolean }
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/workflows/engine.ts")
    const name = args.name || "new-task"
    const dryRun = args.dryRun ?? true
    let inputObj: any = {}
    if (args.input) { try { inputObj = JSON.parse(args.input); if (typeof inputObj === "string") inputObj = { title: inputObj } } catch { inputObj = { title: args.input } } }
    if (args.title) inputObj.title = args.title
    if (args.desc) inputObj.desc = args.desc
    if (!inputObj.title && !args.title) inputObj.title = "Новая задача"
    const parts = ["bun", script, "--workflow", name, "--input", JSON.stringify(inputObj)]
    if (dryRun) parts.push("--dry-run")
    if (args.json) parts.push("--json")
    else parts.push("--json")
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0) throw new Error((out + "\n" + err).trim() || `workflow ${name} failed ${proc.exitCode}`)
    const text = (out + "\n" + err).trim()
    return { content: text }
  },
}
