function buildUrl(db?: string) {
  if (process.env.DATABASE_URL && !db) return process.env.DATABASE_URL
  const host = process.env.POSTGRES_HOST || "localhost"
  const port = process.env.POSTGRES_PORT || "5432"
  const user = process.env.POSTGRES_USER || "postgres"
  const pass = process.env.POSTGRES_PASSWORD || ""
  const database = db || process.env.POSTGRES_DB || process.env.POSTGRES_DATABASE || "postgres"
  const auth = pass ? `${encodeURIComponent(user)}:${encodeURIComponent(pass)}@` : `${encodeURIComponent(user)}@`
  return `postgres://${auth}${host}:${port}/${database}`
}

export type SqlKind = "read" | "dml" | "ddl" | "other"

function classifySql(sql: string): { kind: SqlKind, statements: number, first: string } {
  let s = sql.replace(/\/\*[\s\S]*?\*\//g, " ")
  const lines = s.split("\n").map(l => {
    let out = "", q: string | null = null
    for (let i = 0; i < l.length; i++) {
      const c = l[i]
      if (q) { out += c; if (c === q && l[i-1] !== "\\") q = null; continue }
      if (c === "'" || c === '"') { q = c; out += c; continue }
      if (c === "-" && l[i+1] === "-") break
      out += c
    }
    return out
  })
  s = lines.join("\n")
  let statements = 0, q: string | null = null
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (q) { if (c === q && s[i-1] !== "\\") q = null; continue }
    if (c === "'" || c === '"') { q = c; continue }
    if (c === ";") statements++
  }
  const first = (s.trim().split(";")[0] || "").trim()
  const m = first.match(/^\(?\s*([A-Za-z]+)/)
  const kw = (m ? m[1] : "").toUpperCase()
  let kind: SqlKind = "other"
  if (["SELECT", "WITH", "EXPLAIN", "SHOW", "DESCRIBE", "DESC"].includes(kw)) kind = "read"
  else if (["INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT"].includes(kw)) kind = "dml"
  else if (["CREATE", "ALTER", "DROP", "TRUNCATE", "GRANT", "REVOKE", "COMMENT"].includes(kw)) kind = "ddl"
  if (kw === "WITH" && /\b(INSERT|UPDATE|DELETE|MERGE)\b/i.test(first)) kind = "dml"
  return { kind, statements, first: first.slice(0, 80) }
}

function allowedKinds(permissions: string): SqlKind[] {
  const p = permissions.toLowerCase().replace(/\s+/g, "")
  const out: SqlKind[] = ["read"]
  if (/(^|,)dml(,|$)/.test(p) || p === "write" || p === "all") out.push("dml")
  if (/(^|,)ddl(,|$)/.test(p) || p === "all") out.push("ddl")
  return out
}

export default {
  description: "Postgres (Node, multi-DB, reused host). Обёртка над mcp-postgres + прямым psql. Хост из POSTGRES_HOST, БД — параметром db (переиспользуемый репо). Методы: query (read-only по умолчанию — SELECT/WITH..SELECT/EXPLAIN, enforced до обращения к БД), schema, listTables. Для записи укажи permissions: dml (INSERT/UPDATE/DELETE) и/или ddl (CREATE/ALTER/DROP). Множественные statements через `;` запрещены всегда. Примеры: postgres {db:\"mydb\", sql:\"SELECT * FROM users\"} или {db:\"mydb\", action:\"schema\"}",
  input: {
    type: "object",
    properties: {
      db: { type: "string", description: "Имя БД (меняется, хост один). Если не указано — DATABASE_URL или POSTGRES_DB" },
      sql: { type: "string", description: "SQL запрос (один statement; read по умолчанию, запись только с permissions dml/ddl)" },
      action: { type: "string", enum: ["query", "schema", "listTables"], description: "Действие, default query если sql передан" },
      table: { type: "string", description: "Для schema: имя таблицы (без — все таблицы)" },
      permissions: { type: "string", description: "read (default) | dml | ddl | dml,ddl — enforced: запрещённый тип отклоняется до выполнения" },
    },
    required: [],
    additionalProperties: false,
  },
  async execute(input: any, context: unknown) {
    const args = (input ?? {}) as { db?: string; sql?: string; action?: string; table?: string; permissions?: string }
    const url = buildUrl(args.db)
    const permissions = args.permissions || "read"
    const action = args.action || (args.sql ? "query" : "schema")
    if (action === "query" && args.sql) {
      const c = classifySql(args.sql)
      const allowed = allowedKinds(permissions)
      if (c.statements > 1 || /;\s*\S/.test(args.sql.replace(/\/\*[\s\S]*?\*\//g, ""))) {
        throw new Error(`postgres denied: multiple statements запрещены (найдено разделителей: ${c.statements}). Один statement на вызов.`)
      }
      if (!allowed.includes(c.kind)) {
        throw new Error(`postgres denied: statement типа '${c.kind}' (${c.first}...) требует permissions '${c.kind}', сейчас '${permissions}'. Read-only по умолчанию; запись — только явным permissions.`)
      }
    }
    const hasPsql = (() => {
      try { const p = Bun.spawnSync(["which", "psql"], { stdout: "pipe" }); return p.exitCode === 0 } catch { return false }
    })()
    if (hasPsql && args.sql) {
      const proc = Bun.spawn(["psql", url, "-c", args.sql, "-X", "-q", "-t", "-A", "-F",","], { stdout: "pipe", stderr: "pipe", env: { ...process.env, PGSTATEMENT_TIMEOUT: process.env.PGSTATEMENT_TIMEOUT || "10000" } })
      const out = await new Response(proc.stdout).text()
      const err = await new Response(proc.stderr).text()
      await proc.exited
      const MAX_OUT = 20000
      const result = out.trim().length > MAX_OUT ? out.trim().slice(0, MAX_OUT) + "\n...[truncated]" : out.trim()
      if (proc.exitCode === 0) {
        const text = JSON.stringify({ db: args.db || "(from env)", url: url.replace(/:[^:@]+@/, ":***@"), action, sql: args.sql, permissions, result, via: "psql" }, null, 2)
        return { content: text }
      }
    }
    if (action === "query" && args.sql) {
      const mcpArgs = ["-y", "mcp-postgres", url]
      const proc = Bun.spawn(["npx", ...mcpArgs], { stdin: "pipe", stdout: "pipe", stderr: "pipe" })
      const req = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "query", arguments: { sql: args.sql } } }) + "\n"
      proc.stdin.write(req)
      const t = setTimeout(() => { try { proc.kill() } catch {} }, 3000)
      const out = await new Response(proc.stdout).text().catch(() => "")
      const err = await new Response(proc.stderr).text().catch(() => "")
      await proc.exited.catch(() => {})
      clearTimeout(t)
      if (out.includes("content") || out.includes("result")) {
        const text = JSON.stringify({ db: args.db || "(from env)", url: url.replace(/:[^:@]+@/, ":***@"), via: "mcp-postgres", raw: out.trim(), err: err.trim() }, null, 2)
        return { content: text }
      }
      const text = JSON.stringify({
        db: args.db || "(from env)",
        url: url.replace(/:[^:@]+@/, ":***@"),
        via: "mcp-postgres (stdio)",
        note: "MCP сервер ожидает MCP-клиента (opencode). Прямой вызов из tool — через psql или установи pg. MCP будет доступен автоматически когда DATABASE_URL/POSTGRES_HOST заданы.",
        hint: `Установи: npm i -D pg && используй DATABASE_URL=postgres://user:pass@${process.env.POSTGRES_HOST || "host"}:5432/${args.db || "mydb"}`,
        action, sql: args.sql, permissions, err: err.trim().slice(0, 500), out: out.trim().slice(0, 500)
      }, null, 2)
      return { content: text }
    }
    if (action === "schema" || action === "listTables") {
      const mcpArgs = ["-y", "mcp-postgres", url]
      const proc = Bun.spawn(["npx", ...mcpArgs], { stdin: "pipe", stdout: "pipe", stderr: "pipe" })
      const req = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "schema", arguments: args.table ? { table_name: args.table } : {} } }) + "\n"
      proc.stdin.write(req)
      const t = setTimeout(() => { try { proc.kill() } catch {} }, 3000)
      const out = await new Response(proc.stdout).text().catch(() => "")
      const err = await new Response(proc.stderr).text().catch(() => "")
      await proc.exited.catch(() => {})
      clearTimeout(t)
      const text = JSON.stringify({ db: args.db || "(from env)", via: "mcp-postgres", action, table: args.table, raw: out.trim().slice(0, 2000), err: err.trim().slice(0, 500) }, null, 2)
      return { content: text }
    }
    const text = JSON.stringify({ db: args.db || "(from env)", url: url.replace(/:[^:@]+@/, ":***@"), action, note: "Передай sql для query или action schema/listTables" }, null, 2)
    return { content: text }
  },
}
