#!/usr/bin/env bun
// @ts-nocheck
// 06-verify — программная проверка скрипта: bash -n, shebang, set -euo pipefail,
// --dry-run, executable bit, запреты (rm -rf /, push --force, литеральные секреты).
// shellcheck — если установлен (warn, не gate). Exit всегда 0, итог в поле ok.
// Вход: {scaffold:{script}}
// Выход: {ok, checks:[{id,ok,detail}], _reads}

import { readFileSync, existsSync } from "fs"
import path from "path"
function arg(n: string) { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : undefined }
const p = arg("--input")
let data: any = {}
try { data = JSON.parse(readFileSync(p!, "utf-8")) } catch { }
const rel = data.scaffold?.script || ""
const root = process.cwd()
const full = path.join(root, rel)
const checks: any[] = []
const push = (id: string, ok: boolean, detail: string) => checks.push({ id, ok, detail })

// контент: файл (реальный прогон) или preview (dry-run)
let content = ""
let mode = "file"
try { content = readFileSync(full, "utf-8") } catch { }
if (!content && data.scaffold?.preview?.content) { content = data.scaffold.preview.content; mode = "preview" }
if (!content) {
  push("exists", false, `файл не найден и нет preview: ${rel || "(пусто)"}`)
  console.log(JSON.stringify({ ok: false, checks, _reads: 1 }))
  process.exit(0)
}
push("exists", true, mode === "preview" ? `${rel} (preview, dry-run)` : rel)
push("shebang", content.startsWith("#!/usr/bin/env bash"), "первая строка — #!/usr/bin/env bash")
push("strict", content.includes("set -euo pipefail"), "fail-fast: set -euo pipefail")
push("dry-run", /--dry-run/.test(content), "поддержка --dry-run")

if (mode === "preview") {
  push("syntax", true, "dry-run preview: bash -n выполнится после реальной записи")
} else {
  try {
    const proc = Bun.spawnSync(["bash", "-n", full], { stdout: "pipe", stderr: "pipe" })
    const err = (proc.stderr?.toString() || "").trim()
    push("syntax", proc.exitCode === 0, proc.exitCode === 0 ? "bash -n чист" : `bash -n: ${err.slice(0, 300)}`)
  } catch { push("syntax", false, "bash недоступен") }
}

push("no-rmrf", !/(^|\s|;)rm\s+-rf\s+\/$/.test(content) && !content.includes("rm -rf /"), "нет rm -rf /")
push("no-force-push", !/push\s+--force/.test(content), "нет push --force")
const secretLit = /(?:^|[\s;])(PASSWORD|PASSWD|SECRET|TOKEN|API_KEY)\s*=\s*["'](?!\$\{)[^"']+["']/.test(content)
push("no-secret-literals", !secretLit, secretLit ? "литеральный секрет в коде — только ${VAR} из env" : "секреты только из env")

if (mode === "preview") {
  push("executable", true, "dry-run preview: chmod +x выполнится при записи")
} else {
  try {
    const st = Bun.spawnSync(["test", "-x", full], { stdout: "pipe", stderr: "pipe" })
    push("executable", st.exitCode === 0, st.exitCode === 0 ? "бит +x стоит" : "нет бита +x (chmod +x)")
  } catch { push("executable", true, "skip") }
}

let shellcheck = "skip: shellcheck не установлен"
try {
  const which = Bun.spawnSync(["sh", "-c", "command -v shellcheck"], { stdout: "pipe", stderr: "pipe" })
  if ((which.stdout?.toString() || "").trim()) {
    const sc = Bun.spawnSync(["shellcheck", "-S", "warning", full], { stdout: "pipe", stderr: "pipe" })
    shellcheck = sc.exitCode === 0 ? "shellcheck warning-уровень чист" : `shellcheck warnings:\n${(sc.stdout?.toString() || "").trim().slice(0, 800)}`
  }
} catch { }
checks.push({ id: "shellcheck", ok: true, detail: shellcheck })

const ok = checks.filter((c) => c.id !== "shellcheck").every((c) => c.ok)
console.log(JSON.stringify({ ok, checks, _reads: 2 }))
