// @ts-nocheck
/**
 * pack-tools — регистрация тулов пака в V2-реестре opencode.
 *
 * Кастомные тулы регистрируются только плагином через
 * `ctx.tool.transform`. Без этого все 23 тула пака (классификаторы, скрипты
 * task-manager, worktree, tunnel, postgres) молча исчезают из каталога.
 *
 * Что делает: берёт определения из `tools/*.ts` (V2-форма: `{description,
 * input(JSON Schema), execute}`) и регистрирует через `ctx.tool.transform`
 * после validate-execute (`adapt`: `execute` обязан быть функцией, иначе
 * throw — тула не будет в каталоге).
 * Корень скриптов (`worktree`/`directory`/`cwd`) V2 в контекст вызова НЕ
 * передаёт (там только `sessionID`/`agent`/`signal`), поэтому плагин сам
 * оборачивает `execute` и подставляет корень: явный аргумент тула →
 * контекст вызова → сессия (`ctx.session.get().location.directory`) →
 * `ctx.location.directory` (канонический checkout). Без этого
 * `tools/_resolve.ts` падает на `scripts root unresolved`.
 * Явный корень можно передать аргументами `worktree`/`directory` — плагин
 * добавляет их в схему каждого тула и вырезает из входа перед вызовом
 * (нужно хостед-обвязке, где каталог в контексте недоступен).
 * Резолв самой раскладки (consumer `.opencode/` vs сам пак) остаётся в
 * `tools/_resolve.ts`: строго `<root>/.opencode/scripts/<rel>`, затем
 * `<root>/scripts/<rel>` — без тихих фолбэков, иначе throw.
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

/** Ключи, которыми можно передать корень репозитория аргументом тула. */
const ROOT_KEYS = ["worktree", "directory", "cwd"] as const

type AnyContext = { worktree?: string; directory?: string; cwd?: string; sessionID?: string; signal?: AbortSignal } | undefined

/** Корень скриптов: явный аргумент → контекст вызова → сессия → канонический checkout. */
async function resolveRoot(ctx: any, context: AnyContext, explicit?: string): Promise<string> {
  if (typeof explicit === "string" && explicit) return explicit
  const direct = context?.worktree ?? context?.directory ?? context?.cwd
  if (typeof direct === "string" && direct) return direct
  const sessionID = context?.sessionID
  if (sessionID && typeof ctx?.session?.get === "function") {
    try {
      const session = await ctx.session.get({ sessionID })
      const dir = session?.location?.directory
      if (typeof dir === "string" && dir) return dir
    } catch {
      // сессия недоступна — падаем на канонический checkout
    }
  }
  const fallback = ctx?.location?.directory ?? ctx?.location?.project?.directory
  if (typeof fallback === "string" && fallback) return fallback
  throw new Error("[pack-tools] scripts root unresolved: нет ни аргумента worktree/directory, ни сессии, ни location")
}

/** Вырезает корень из входа тула, чтобы не ломал `additionalProperties: false` внутри определений. */
function splitRoot(input: unknown): { args: unknown; root?: string } {
  if (!input || typeof input !== "object" || Array.isArray(input)) return { args: input }
  const args: Record<string, unknown> = { ...(input as Record<string, unknown>) }
  let root: string | undefined
  for (const key of ROOT_KEYS) {
    const value = args[key]
    if (typeof value === "string" && value) {
      root ??= value
      delete args[key]
    }
  }
  return { args, root }
}

/** Добавляет в схему входа необязательный корень: хостед-обвязка не может отдать каталог контекстом. */
function withRootInput(definition: any): any {
  const input = definition?.input
  if (!input || input.type !== "object" || typeof input.properties !== "object") return definition
  if (input.properties.directory || input.properties.worktree) return definition
  return {
    ...definition,
    input: {
      ...input,
      properties: {
        ...input.properties,
        worktree: { type: "string", description: "Корень worktree (приоритетнее directory), если контекст вызова без каталога" },
        directory: { type: "string", description: "Корень consumer-репо, если контекст вызова без каталога" },
      },
    },
  }
}

function adapt(name: string, definition: any, ctx: any) {
  if (typeof definition?.execute !== "function") {
    throw new Error(`[pack-tools] ${name}: определение тула без execute()`)
  }
  const prepared = withRootInput(definition)
  return {
    ...prepared,
    name,
    async execute(input: unknown, context: AnyContext) {
      const { args, root } = splitRoot(input)
      const resolved = await resolveRoot(ctx, context, root)
      return prepared.execute(args ?? {}, {
        ...(context ?? {}),
        worktree: resolved,
        directory: resolved,
        cwd: resolved,
        abort: () => context?.signal,
      })
    },
  }
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