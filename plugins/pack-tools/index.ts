// @ts-nocheck
/**
 * pack-tools — регистрация тулов пака в V2-реестре opencode.
 *
 * Кастомные тулы регистрируются только плагином через
 * `ctx.tool.transform`. Без этого все 23 тула пака (классификаторы, скрипты
 * task-manager, worktree, tunnel, postgres) молча исчезают из каталога.
 *
 * Что делает: берёт определения из `tools/*.ts` (V2-форма: `{description,
 * input(JSON Schema), execute}`) и регистрирует как есть через
 * `ctx.tool.transform` после validate-execute (`adapt`: `execute` обязан
 * быть функцией, иначе throw — тула не будет в каталоге).
 * Резолв корня скриптов и раскладки (consumer `.opencode/` vs сам пак)
 * живёт в `tools/_resolve.ts`: `resolveScript(scriptRel, context)` берёт
 * `worktree/directory/cwd` из контекста вызова и ищет строго
 * `<root>/.opencode/scripts/<rel>`, затем `<root>/scripts/<rel>` —
 * без тихих фолбэков, иначе throw.
 * `{name}` = имя файла в `tools/`.
 */
import boards from "../../tools/boards.ts"
import check from "../../tools/check.ts"
import classify_build from "../../tools/classify_build.ts"
import classify_plan from "../../tools/classify_plan.ts"
import classify_task from "../../tools/classify_task.ts"
import commit_trello from "../../tools/commit_trello.ts"
import git_changes from "../../tools/git_changes.ts"
import graphify from "../../tools/graphify.ts"
import lists from "../../tools/lists.ts"
import planner from "../../tools/planner.ts"
import postgres from "../../tools/postgres.ts"
import task_audit from "../../tools/task_audit.ts"
import task_checklist from "../../tools/task_checklist.ts"
import task_commits from "../../tools/task_commits.ts"
import task_create from "../../tools/task_create.ts"
import task_dump from "../../tools/task_dump.ts"
import task_find_duplicates from "../../tools/task_find_duplicates.ts"
import task_init from "../../tools/task_init.ts"
import task_label from "../../tools/task_label.ts"
import task_move from "../../tools/task_move.ts"
import tunnel from "../../tools/tunnel.ts"
import worktree from "../../tools/worktree.ts"
import workflow from "../../tools/workflow.ts"

/** Имя тула = имя файла в `tools/` — на них ссылаются промпты агентов и `permissions`. */
const TOOLS: Record<string, unknown> = {
  boards,
  check,
  classify_build,
  classify_plan,
  classify_task,
  commit_trello,
  git_changes,
  graphify,
  lists,
  planner,
  postgres,
  task_audit,
  task_checklist,
  task_commits,
  task_create,
  task_dump,
  task_find_duplicates,
  task_init,
  task_label,
  task_move,
  tunnel,
  worktree,
  workflow,
}

function adapt(name: string, definition: any, ctx: any) {
  if (typeof definition?.execute !== "function") {
    throw new Error(`[pack-tools] ${name}: определение тула без execute()`)
  }
  return { name, ...definition }
}

export default {
  id: "pack-tools",
  async setup(ctx: any) {
    if (!ctx?.tool || typeof ctx.tool.transform !== "function") throw new Error("[pack-tools] ctx.tool.transform недоступен — тулы не зарегистрированы")
    await ctx.tool.transform((editor: any) => {
      for (const [name, definition] of Object.entries(TOOLS)) {
        editor.add(adapt(name, definition, ctx))
      }
    })

    const registered = Object.keys(TOOLS)
    console.log(`[pack-tools] registered ${registered.length}: ${registered.join(", ")}`)
    if (globalThis.process?.env?.PACK_TOOLS_DEBUG === "1") {
      const snapshot = await ctx.tool.list()
      const payload = snapshot.map((entry: any) => ({ id: entry.id, name: entry.name }))
      if (typeof Bun !== "undefined") await Bun.write("/tmp/pack-tools-registered.json", JSON.stringify(payload, null, 2))
      console.log(`[pack-tools] debug snapshot: ${JSON.stringify(payload)}`)
    }
  },
}