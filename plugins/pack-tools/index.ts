// @ts-nocheck
/**
 * pack-tools — регистрация тулов пака в V2-реестре opencode.
 *
 * Зачем: V1 грузил `.opencode/tool/*.ts` автоматически. В V2 автозагрузки
 * каталога тулов нет (в бинаре opencode есть `.opencode/plugin(s)/`, строки
 * `.opencode/tool` нет), кастомные тулы регистрируются только плагином через
 * `ctx.tool.transform`. Без этого все 23 тула пака (классификаторы, скрипты
 * task-manager, worktree, tunnel, postgres) молча исчезают из каталога.
 *
 * Что делает: берёт определения из `tools/*.ts` (V1-форма: `tool({args, execute})`,
 * где args — zod-схемы) и регистрирует их как V2 ToolInfo:
 *   - `args` (zod) → `input` (JSON Schema, `$schema` вырезается);
 *   - `execute(args, ctx)` → `execute(input, ctx)`, результат-строка → `{content}`;
 *   - V1-контекст (`worktree`/`directory`) собирается из V2-контекста вызова,
 *     при отсутствии — из сессии (`ctx.session.get`) и как последний рубеж из
 *     `ctx.location.directory` (канонический checkout).
 *
 * Определения в `tools/` остаются единственным источником правды: конвертация
 * происходит на регистрации, файлы тулов не дублируются и не расходятся с
 * зарегистрированной схемой.
 */
import { z } from "zod"

import boards from "../../tools/boards.js"
import check from "../../tools/check.js"
import classify_build from "../../tools/classify_build.js"
import classify_plan from "../../tools/classify_plan.js"
import classify_task from "../../tools/classify_task.js"
import commit_trello from "../../tools/commit_trello.js"
import git_changes from "../../tools/git_changes.js"
import graphify from "../../tools/graphify.js"
import lists from "../../tools/lists.js"
import planner from "../../tools/planner.js"
import postgres from "../../tools/postgres.js"
import task_audit from "../../tools/task_audit.js"
import task_checklist from "../../tools/task_checklist.js"
import task_commits from "../../tools/task_commits.js"
import task_create from "../../tools/task_create.js"
import task_dump from "../../tools/task_dump.js"
import task_find_duplicates from "../../tools/task_find_duplicates.js"
import task_init from "../../tools/task_init.js"
import task_label from "../../tools/task_label.js"
import task_move from "../../tools/task_move.js"
import tunnel from "../../tools/tunnel.js"
import worktree from "../../tools/worktree.js"
import workflow from "../../tools/workflow.js"

/** Имя тула = имя файла в `tools/` — на них ссылаются промпты агентов и `permission.tool`. */
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

type Schema = { safeParse?: (value: unknown) => { success: boolean }; description?: string }

function stripInternals(schema: unknown): unknown {
  if (Array.isArray(schema)) return schema.map(stripInternals)
  if (!schema || typeof schema !== "object") return schema
  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(schema as Record<string, unknown>)) {
    if (key === "$schema") continue
    out[key] = stripInternals(value)
  }
  return out
}

/** zod-args → JSON Schema объекта-входа тула. Опциональность — через safeParse, а не по флагам. */
function toInputSchema(args: Record<string, Schema> = {}): Record<string, unknown> {
  const properties: Record<string, unknown> = {}
  const required: string[] = []
  for (const [key, schema] of Object.entries(args)) {
    properties[key] = stripInternals(z.toJSONSchema(schema, { io: "input" }))
    if (schema?.safeParse && !schema.safeParse(undefined).success) required.push(key)
  }
  return { type: "object", properties, required, additionalProperties: false }
}

/** Результат V1-тула (строка/объект) → V2 `{content}`. */
function toContent(result: unknown): { content: string | unknown[] } {
  if (typeof result === "string") return { content: result }
  if (Array.isArray(result)) return { content: result }
  if (result && typeof result === "object") {
    const content = (result as { content?: unknown }).content
    if (typeof content === "string" || Array.isArray(content)) return { content: content as string }
    return { content: JSON.stringify(result, null, 2) }
  }
  return { content: String(result ?? "") }
}

type V2ToolContext = {
  worktree?: string
  directory?: string
  cwd?: string
  sessionID?: string
  signal?: AbortSignal
}

/** Корень проекта для скриптов пака: контекст вызова → сессия → канонический checkout. */
async function resolveRoot(ctx: any, context: V2ToolContext | undefined): Promise<string> {
  const direct = context?.worktree ?? context?.directory ?? context?.cwd
  if (typeof direct === "string" && direct) return direct
  const sessionID = context?.sessionID
  if (sessionID) {
    try {
      const session = await ctx.session.get({ sessionID })
      const dir = session?.location?.directory
      if (typeof dir === "string" && dir) return dir
    } catch {
      // сессия недоступна — падаем на канонический checkout
    }
  }
  return ctx.location.directory
}

function adapt(name: string, definition: any, ctx: any) {
  if (typeof definition?.execute !== "function") {
    throw new Error(`[pack-tools] ${name}: определение тула без execute()`)
  }
  // V2-форма уже (input вместо args) — регистрируем как есть.
  if (definition.input && !definition.args) return { name, ...definition }

  return {
    name,
    description: definition.description ?? `Пак-тул ${name}`,
    input: toInputSchema(definition.args),
    async execute(input: unknown, context: V2ToolContext) {
      const root = await resolveRoot(ctx, context)
      const legacyContext = {
        ...context,
        worktree: root,
        directory: root,
        abort: () => context?.signal,
      }
      return toContent(await definition.execute(input ?? {}, legacyContext))
    },
  }
}

export default {
  id: "pack-tools",
  async setup(ctx: any) {
    await ctx.tool.transform((editor: any) => {
      for (const [name, definition] of Object.entries(TOOLS)) {
        editor.add(adapt(name, definition, ctx))
      }
    })

    const registered = Object.keys(TOOLS)
    console.log(`[pack-tools] registered ${registered.length}: ${registered.join(", ")}`)
    if (process.env.PACK_TOOLS_DEBUG === "1") {
      const snapshot = await ctx.tool.list()
      const payload = snapshot.map((entry: any) => ({ id: entry.id, name: entry.name }))
      await Bun.write("/tmp/pack-tools-registered.json", JSON.stringify(payload, null, 2))
      console.log(`[pack-tools] debug snapshot: ${JSON.stringify(payload)}`)
    }
  },
}