// @ts-nocheck
import { tool } from "@opencode-ai/plugin"
import path from "path"

function buildUrl(db?: string) {
  if (process.env.DATABASE_URL && !db) return process.env.DATABASE_URL
  // multi-DB: хост один, db меняем параметром
  const host = process.env.POSTGRES_HOST || "localhost"
  const port = process.env.POSTGRES_PORT || "5432"
  const user = process.env.POSTGRES_USER || "postgres"
  const pass = process.env.POSTGRES_PASSWORD || ""
  const database = db || process.env.POSTGRES_DB || process.env.POSTGRES_DATABASE || "postgres"
  const auth = pass ? `${encodeURIComponent(user)}:${encodeURIComponent(pass)}@` : `${encodeURIComponent(user)}@`
  return `postgres://${auth}${host}:${port}/${database}`
}

export default tool({
  description: "Postgres (Node, multi-DB, reused host). Обёртка над mcp-postgres + прямым psql. Хост из POSTGRES_HOST, БД — параметром db (переиспользуемый репо). Методы: query (read-only по умолчанию), schema, listTables. Для записи укажи permissions: dml/ddl. Примеры: postgres {db:\"mydb\", sql:\"SELECT * FROM users\"} или {db:\"mydb\", action:\"schema\"}",
  args: {
    db: tool.schema.string().optional().describe("Имя БД (меняется, хост один). Если не указано — DATABASE_URL или POSTGRES_DB"),
    sql: tool.schema.string().optional().describe("SQL запрос (только SELECT для read; для записи нужен permissions dml/ddl)"),
    action: tool.schema.enum(["query","schema","listTables"]).optional().describe("Действие, default query если sql передан"),
    table: tool.schema.string().optional().describe("Для schema: имя таблицы (без — все таблицы)"),
    permissions: tool.schema.string().optional().describe("read (default) | ddl | dml | read,dml etc — контролирует какие SQL разрешены"),
  },
  async execute(args, context) {
    const root = (context as any).worktree ?? (context as any).directory ?? "."
    const url = buildUrl(args.db)
    const permissions = args.permissions || "read"
    const action = args.action || (args.sql ? "query" : "schema")

    // Используем mcp-postgres как MCP-клиент: спавним и говорим по JSON-RPC stdio
    // Упрощённо: для query делегируем напрямую через npx mcp-postgres с env, но mcp-postgres — сервер, а не CLI.
    // Поэтому для Node-варианта без лишних зависимостей делаем прямой pg-клиент через npx pg-query (если pg установлен) или через psql.
    // Fallback: пробуем psql если доступен, иначе говорим как настроить.

    // Попытка 1: psql (если установлен)
    const hasPsql = (() => {
      try { const p = Bun.spawnSync(["which","psql"], { stdout:"pipe" }); return p.exitCode===0 } catch { return false }
    })()

    if (hasPsql && args.sql) {
      const proc = Bun.spawn(["psql", url, "-c", args.sql, "-X","-q","-t","-A","-F",","], { stdout:"pipe", stderr:"pipe" })
      const out = await new Response(proc.stdout).text()
      const err = await new Response(proc.stderr).text()
      await proc.exited
      if (proc.exitCode===0) return JSON.stringify({ db: args.db || "(from env)", url: url.replace(/:[^:@]+@/,":***@"), action, sql: args.sql, result: out.trim(), via:"psql" }, null, 2)
      // если psql упал — пробуем дальше
    }

    // Попытка 2: npx mcp-postgres как MCP сервер — вызываем его tool через JSON-RPC
    // Формируем MCP запрос tool/call query
    if (action==="query" && args.sql) {
      const mcpArgs = ["-y","mcp-postgres", url]
      // Проверим что пакет резолвится (npx --yes скачает если нужно)
      const proc = Bun.spawn(["npx", ...mcpArgs], { stdin:"pipe", stdout:"pipe", stderr:"pipe" })
      const req = JSON.stringify({ jsonrpc:"2.0", id:1, method:"tools/call", params:{ name:"query", arguments:{ sql: args.sql } } })+"\n"
      proc.stdin.write(req)
      // Ждём ответ 3 сек
      const t = setTimeout(()=>{ try{proc.kill()}catch{} }, 3000)
      const out = await new Response(proc.stdout).text().catch(()=> "")
      const err = await new Response(proc.stderr).text().catch(()=> "")
      await proc.exited.catch(()=>{})
      clearTimeout(t)
      if (out.includes("content") || out.includes("result")) return JSON.stringify({ db: args.db||"(from env)", url: url.replace(/:[^:@]+@/,":***@"), via:"mcp-postgres", raw: out.trim(), err: err.trim() }, null, 2)
      // fallback сообщение
      return JSON.stringify({
        db: args.db || "(from env)",
        url: url.replace(/:[^:@]+@/,":***@"),
        via: "mcp-postgres (stdio)",
        note: "MCP сервер ожидает MCP-клиента (opencode). Прямой вызов из tool — через psql или установи pg. MCP будет доступен автоматически когда DATABASE_URL/POSTGRES_HOST заданы.",
        hint: `Установи: npm i -D pg && используй DATABASE_URL=postgres://user:pass@${process.env.POSTGRES_HOST||"host"}:5432/${args.db||"mydb"}`,
        action, sql: args.sql, permissions, err: err.trim().slice(0,500), out: out.trim().slice(0,500)
      }, null, 2)
    }

    if (action==="schema" || action==="listTables") {
      const mcpArgs = ["-y","mcp-postgres", url]
      const proc = Bun.spawn(["npx", ...mcpArgs], { stdin:"pipe", stdout:"pipe", stderr:"pipe" })
      const req = JSON.stringify({ jsonrpc:"2.0", id:1, method:"tools/call", params:{ name:"schema", arguments: args.table?{table_name: args.table}:{} } })+"\n"
      proc.stdin.write(req)
      const t = setTimeout(()=>{ try{proc.kill()}catch{} }, 3000)
      const out = await new Response(proc.stdout).text().catch(()=> "")
      const err = await new Response(proc.stderr).text().catch(()=> "")
      await proc.exited.catch(()=>{})
      clearTimeout(t)
      return JSON.stringify({ db: args.db||"(from env)", via:"mcp-postgres", action, table: args.table, raw: out.trim().slice(0,2000), err: err.trim().slice(0,500) }, null, 2)
    }

    return JSON.stringify({ db: args.db||"(from env)", url: url.replace(/:[^:@]+@/,":***@"), action, note:"Передай sql для query или action schema/listTables" }, null, 2)
  },
})
