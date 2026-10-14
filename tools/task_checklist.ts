// @ts-nocheck
import { z } from "zod"
import path from "path"
export default {
  description: "Чек-листы Trello-карточки (подзадачи). Обёртка над scripts/task-manager/checklist.sh. Действия: show/create/add-item/complete/complete-all/uncomplete.",
  args: {
    id: z.string().optional().describe("ID карточки"),
    url: z.string().optional().describe("URL карточки"),
    card: z.string().optional().describe("Точное имя карточки"),
    from_board: z.string().optional().describe("Сузить поиск по доске при --card"),
    list: z.string().optional().describe("Точное имя чек-листа (если на карточке один — можно опустить)"),
    show: z.boolean().optional().describe("Показать чек-листы JSON"),
    create: z.string().optional().describe("Создать чек-лист с именем"),
    items: z.string().optional().describe("Пункты через ; для --create, напр. \"Шаг 1;Шаг 2\""),
    add_item: z.string().optional().describe("Добавить пункт в чек-лист"),
    complete: z.string().optional().describe("Отметить пункт как выполненный (точное имя)"),
    complete_all: z.boolean().optional().describe("Отметить все пункты чек-листа"),
    uncomplete: z.string().optional().describe("Снять отметку с пункта"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const script = path.join(root, ".opencode/scripts/task-manager/checklist.sh")
    const parts = ["bash", script]
    if (args.id) parts.push("--id", args.id)
    if (args.url) parts.push("--url", args.url)
    if (args.card) parts.push("--card", args.card)
    if (args.from_board) parts.push("--from-board", args.from_board)
    if (args.list) parts.push("--list", args.list)
    if (args.show) parts.push("--show")
    if (args.create) parts.push("--create", args.create)
    if (args.items) parts.push("--items", args.items)
    if (args.add_item) parts.push("--add-item", args.add_item)
    if (args.complete) parts.push("--complete", args.complete)
    if (args.complete_all) parts.push("--complete-all")
    if (args.uncomplete) parts.push("--uncomplete", args.uncomplete)
    const proc = Bun.spawn(parts, { cwd: root, stdout: "pipe", stderr: "pipe" })
    const out = await new Response(proc.stdout).text()
    const err = await new Response(proc.stderr).text()
    await proc.exited
    if (proc.exitCode !== 0) throw new Error((out + "\n" + err).trim() || `checklist failed ${proc.exitCode}`)
    return (out + "\n" + err).trim()
  },
}
