#!/usr/bin/env bun
// @ts-nocheck
// 05-scaffold — пишет scripts/cicd/<slug>.sh по плану (детерминированный UNIX-скелет).
// Одна функция — одна стадия; композиция через &&; set -euo pipefail; --dry-run;
// stdout — данные, stderr — логи; секреты только из env. Заблокированные стадии —
// честные TODO-заглушки (return 0), не рабочий код. В dry-run — только preview.
// Вход: {plan:{stages}, classify:{pipeline_type}, input:{title}}
// Выход: {script, lines, stages, blocked, preview?, overflow, _writes}

import { readFileSync, existsSync, mkdirSync, writeFileSync, chmodSync } from "fs"
import path from "path"
function arg(n: string) { const i = process.argv.indexOf(n); return i !== -1 ? process.argv[i + 1] : undefined }
const dryRun = process.argv.includes("--dry-run") || process.argv.includes("--dryRun")
const p = arg("--input")
let data: any = {}
try { data = JSON.parse(readFileSync(p!, "utf-8")) } catch { }
const stages: any[] = data.plan?.stages || []
const pipeline_type = data.classify?.pipeline_type || "ci-gate"
const tRaw5 = data.target || {}
const orchestrator5 = tRaw5.spec?.orchestrator || tRaw5.orchestrator || tRaw5.target?.orchestrator || data.spec?.orchestrator || "unknown"
const title = data.input?.title || "pipeline"
const root = process.cwd()

let slug = (title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "").slice(0, 30)
if (slug.length < 8) slug = `${pipeline_type}-pipeline` // кириллический title даёт мусор вроде bash.sh
const rel = `scripts/cicd/${slug}.sh`
const full = path.join(root, rel)

const stageFns = stages.map((s) => {
  const body = s.blocked_by && s.blocked_by.length
    ? `  log "TODO(${s.blocked_by.join(",")}): ${s.title} — закрыть gap, затем вписать команду"`
      + "\n  return 0"
    : `  run ${s.cmd}`
  return `stage_${s.id}() { # ${s.title}\n  log "${s.id}..."\n${body}\n}`
})

const chain = stages.map((s) => `stage_${s.id}`).join(" && ") || "true"

const lines = [
  "#!/usr/bin/env bash",
  `# ${slug}.sh — ${pipeline_type} pipeline, orchestrator ${orchestrator5} (workflow cicd-script).`,
  "# UNIX-way: одна функция — одна задача, композиция через &&, idempotent, --dry-run.",
  "# Секреты только из окружения, никогда литералами.",
  "set -euo pipefail",
  "",
  "DRY_RUN=0",
  "usage() {",
  `  echo "Usage: ${rel} [--dry-run] [-h|--help]"`,
  '  echo "Env: REGISTRY IMAGE_NAME IMAGE_TAG DEPLOY_HOST DEPLOY_DIR (секреты — только env)"',
  "}",
  'log() { echo "[' + slug + '] $*" >&2; }',
  'run() { if [[ "${DRY_RUN}" -eq 1 ]]; then echo "+ $*"; else "$@"; fi; }',
  "",
  ...stageFns,
  "",
  "main() {",
  "  while [[ $# -gt 0 ]]; do",
  '    case "$1" in',
  "      --dry-run) DRY_RUN=1 ;;",
  "      -h|--help) usage; exit 0 ;;",
  "      *) usage >&2; exit 2 ;;",
  "    esac",
  "    shift",
  "  done",
  `  ${chain}`,
  "}",
  'main "$@"',
  "",
]
const content = lines.join("\n")
const lineCount = lines.length
const overflow = lineCount > 120

if (dryRun) {
  console.log(JSON.stringify({
    script: rel, lines: lineCount, stages: stages.map((s) => s.id),
    blocked: stages.filter((s) => (s.blocked_by || []).length).map((s) => s.id),
    preview: { path: rel, content }, overflow, _writes: 0,
  }))
  process.exit(0)
}

mkdirSync(path.dirname(full), { recursive: true })
writeFileSync(full, content)
try { chmodSync(full, 0o755) } catch { }
console.log(JSON.stringify({
  script: rel, lines: lineCount, stages: stages.map((s) => s.id),
  blocked: stages.filter((s) => (s.blocked_by || []).length).map((s) => s.id),
  overflow, _writes: 1,
}))
