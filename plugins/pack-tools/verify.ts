// Offline verification for the pack-tools plugin: registers the pack tools
// against a fake V2 context, then exercises two of them for real.
// Run: bun scripts/../plugins/pack-tools/verify.ts  (see AGENTS.md)
import plugin from "./index.ts"

const ROOT = process.env.PACK_TOOLS_TEST_ROOT ?? process.cwd()
const added: Record<string, any> = {}

const ctx: any = {
  location: { directory: ROOT },
  session: {
    get: async ({ sessionID }: { sessionID: string }) => {
      if (sessionID !== "ses-test") throw new Error("no session")
      return { id: sessionID, location: { directory: ROOT } }
    },
  },
  tool: {
    transform: async (cb: (editor: any) => void) => {
      cb({
        add: (def: any) => {
          added[def.name] = def
        },
      })
    },
    list: async () => Object.values(added).map((t: any) => ({ id: t.name, name: t.name })),
  },
  storage: { get: async () => undefined, set: async () => {}, scan: async () => ({ keys: [] }) },
}

let failures = 0
function check(label: string, ok: boolean, detail = "") {
  console.log(`${ok ? "ok  " : "FAIL"} ${label}${detail ? ` — ${detail}` : ""}`)
  if (!ok) failures++
}

await plugin.setup(ctx)

const names = Object.keys(added).sort()
check("все 23 тула зарегистрированы", names.length === 23, `получено ${names.length}`)
for (const expected of ["classify_build", "classify_plan", "classify_task", "graphify", "worktree", "workflow", "postgres", "check"]) {
  check(`тул ${expected} в реестре`, expected in added)
}

for (const [name, def] of Object.entries(added)) {
  const schema = def.input
  const schemaOk =
    schema &&
    schema.type === "object" &&
    typeof schema.properties === "object" &&
    Array.isArray(schema.required) &&
    schema.additionalProperties === false
  check(`схема входа корректна: ${name}`, Boolean(schemaOk))
  check(`нет $schema в свойствах: ${name}`, !JSON.stringify(schema).includes('"$schema"'))
  check(`описание не пустое: ${name}`, typeof def.description === "string" && def.description.length > 0)
}

// классификатор — чистая логика, реальный вызов
const classified = await added.classify_build.execute({
  title: "Добавить редактирование схем в visual-режиме OpenAPI",
  desc: "## Что сделать\nСекция Schemas в widgets/openapi-visual\n## Критерии приёмки\nCRUD + композиции",
  level: "high",
  files: 13,
  deps: 5,
  type: "add",
  risk_level: "medium",
})
const parsed = JSON.parse(classified.content)
check("classify_build вернул JSON", typeof parsed.builder === "string", `builder=${parsed.builder}`)
check("classify_build выбрал исполнителя", ["build-fast", "build-smart", "devops", "build"].includes(parsed.builder))

// корень из сессии, когда в контексте вызова его нет
const viaSession = await added.classify_build.execute({ title: "task", desc: "x".repeat(40) }, { sessionID: "ses-test" })
check("корень резолвится через сессию", typeof viaSession.content === "string" && viaSession.content.length > 0)

// реальный вызов скриптового тула: worktree list в фейковом consumer-репо
const listed = await added.worktree.execute({ command: "list", json: true }, { directory: ROOT })
check("worktree list вернул вывод", listed.content.trim().length > 0, listed.content.split("\n")[0]?.slice(0, 80))

console.log(failures === 0 ? "\nвсе проверки прошли" : `\nпровалено проверок: ${failures}`)
process.exit(failures === 0 ? 0 : 1)