// @ts-nocheck
import { z } from "zod"

export default {
  description: "Классификатор build+preview: выбирает build-fast (low), build-smart (medium/high), devops (инфра/деплои) или build (default fallback) и needs_tunnel (нужен ли preview-тоннель). Принимает complexity/risk от evol-plan или сырые поля задачи. Применяет детерминированные правила, затем Jev (systemone choice) → fallback на эвристику → build по умолчанию. Возвращает JSON {builder, confidence, reason, provider, needs_tunnel, tunnel_reason}.",
  args: {
    title: z.string().optional().describe("Заголовок задачи / карточки Trello"),
    desc: z.string().optional().describe("Описание задачи (## Что сделать / Критерии)"),
    level: z.enum(["low", "medium", "high"]).optional().describe("Уровень сложности из evol-plan"),
    score: z.number().optional().describe("Score сложности 0-20"),
    files: z.number().optional().describe("Кол-во файлов в задаче"),
    deps: z.number().optional().describe("Кол-во зависимостей"),
    type: z.enum(["add", "update", "delete", "decompose"]).optional().describe("Тип изменения"),
    unknowns: z.number().optional().describe("Неопределённость"),
    risk_level: z.enum(["low", "medium", "high"]).optional().describe("Уровень риска"),
    risk_score: z.number().optional().describe("Риск score 0-8"),
    risk_factors: z.array(z.string()).optional().describe("Факторы риска: breaking,data,security,external"),
  },
  async execute(args, context) {
    const hasTitle = !!(args.title && args.title.trim())
    const hasDesc = !!(args.desc && args.desc.trim())
    const hasLevel = !!args.level
    const hasScore = args.score !== undefined
    const hasFiles = args.files !== undefined
    const input = {
      title: args.title ?? "",
      desc: args.desc ?? "",
      level: args.level ?? "medium",
      score: args.score ?? 5,
      files: args.files ?? 1,
      deps: args.deps ?? 0,
      type: args.type ?? "update",
      unknowns: args.unknowns ?? 0,
      risk_level: args.risk_level ?? "low",
      risk_score: args.risk_score ?? 0,
      risk_factors: args.risk_factors ?? [],
    }

    // ——— devops detection (высший приоритет, наравне с dependency) ———
    // Инфра/деплои → devops: docker-образы, dev/prod окружения, сети/порты/volumes, cgroups-лимиты, restart-политики
    const combinedText = `${input.title} ${input.desc}`
    const strongDevopsPattern =
      /(dockerfile|docker-compose|docker\s+compose|докер|контейнер|docker\s+(image|образ|build|run|push)|compose\.ya?ml|\.env\.(dev|prod|example)|dev\s*\/\s*prod|cgroup|unless-stopped|always\s*:\s*true|swarm|kubernetes|\bk8s\b|kubectl|helm)/i
    const hasEnvWord = /(окружени|environment|\.env)/i.test(combinedText)
    const hasInfraCtx = /(dev|prod|docker|compose|контейнер|config|деплой|deploy)/i.test(combinedText)
    const hasNetWord =
      /volumes?:|вольюм|expose|ports:\s*\n?\s*-|проброс.*порт|политик.*переза|перезапуск.*(политик|сервис|контейнер)|restart:\s*\w+|лимит.*(памят|memory|cpu)|огранич.*ресурс|deploy:\s*\n?\s*resources|resources:\s*\n?\s*limits?|healthcheck:/i.test(
        combinedText,
      )
    const hasNetWordCtx =
      /(^|[\s:"'`(\-])сет[ьию]([\s:"',.\-)]|$)|network/i.test(combinedText) && hasInfraCtx
    const hasPortWordCtx =
      /(^|[\s:"'`(\-])порты?(?:а|у|ом|ов)?([\s:"',.\-)]|$)/i.test(combinedText) && hasInfraCtx
    // CI/CD bash-скрипты → devops (а не @ci: тот делает YAML .github/workflows,
    // devops — исполнимые scripts/cicd/*.sh в UNIX-философии)
    const hasCicdWord = /(ci\/cd|cicd|пайплайн|pipeline)/i.test(combinedText)
    const hasScriptCtx = /(bash|shell|скрипт|\.sh\b|автоматизац)/i.test(combinedText)
    const hasDeployScript = /(депло|deploy|релиз|release)/i.test(combinedText) && hasScriptCtx
    const isDevopsTask =
      strongDevopsPattern.test(combinedText) ||
      (hasEnvWord && hasInfraCtx) ||
      (hasNetWord && hasInfraCtx) ||
      hasNetWordCtx ||
      hasPortWordCtx ||
      (hasCicdWord && hasScriptCtx) ||
      hasDeployScript

    // ——— dependency detection (высший приоритет над risk/level) ———
    // Любая работа с зависимостями → build-smart: требует изоляции, пошаговости и верификации
    const dependencyPattern =
      /(зависимост|dependencies|dependency|package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lock|poetry\.lock|requirements\.txt|pyproject\.toml|Pipfile|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock|Gemfile|composer\.json|обнов.*зависим|update.*depend|upgrade.*depend|bump.*depend|outdated|npm\s+(up|update|audit|install)|pnpm\s+(up|update|add|install)|yarn\s+(up|upgrade|add)|pip\s+install|poetry\s+(add|update)|go\s+(get|mod)|cargo\s+update)/i
    const isDependencyTask = dependencyPattern.test(combinedText)

    const isInsufficient = !hasTitle && !hasDesc && !hasLevel && !hasScore && !hasFiles && (args.unknowns ?? 0) >= 2

    const needsTunnelHeuristic = (() => {
      const text = `${input.title} ${input.desc}`.toLowerCase()
      if (/(превью|покажи|открой|tunnel|preview|loca\.lt|ngrok)/i.test(text)) return { needs: true, reason: "keyword preview/tunnel в задаче" }
      if (/(frontend|ui|верст|страниц|компонент)/i.test(text) && input.type === "add") return { needs: false, reason: "ui без явного preview — тоннель опционален" }
      return { needs: false, reason: "no preview keyword" }
    })()

    // devops override — до эвристики, наравне с dependency (инфра-интент шире кодового)
    if (isDevopsTask) {
      return JSON.stringify(
        {
          builder: "devops",
          confidence: 0.93,
          reason: "инфра/деплой (docker, dev/prod, сети/порты/volumes, лимиты, restart) → devops",
          provider: "heuristic",
          needs_tunnel: needsTunnelHeuristic.needs,
          tunnel_reason: needsTunnelHeuristic.reason,
          hint: "держи dev/prod в паре (compose base+override+prod, .env.example/dev/prod), явные networks/ports/volumes, prod-лимиты deploy.resources + restart unless-stopped, обнови README ## Окружение; проверь docker compose config + build",
          input,
          meta: { isDevopsTask: true },
        },
        null,
        2,
      )
    }

    // dependency override — до эвристики
    if (isDependencyTask) {
      return JSON.stringify(
        {
          builder: "build-smart",
          confidence: 0.95,
          reason: "работа с зависимостями → build-smart (sequential поштучно, worktree + forward-only, откат ≤ baseCommit)",
          provider: "heuristic",
          needs_tunnel: needsTunnelHeuristic.needs,
          tunnel_reason: needsTunnelHeuristic.reason,
          hint: "обновляй зависимости друг за другом (по одной), проверяй сборку/тесты после каждой; при ошибке — откат к последнему успешному коммиту, но не раньше baseCommit (коммит назначения задачи); итог: 0..N коммитов вперёд, никогда отрицательно; предпочтительно в worktree",
          input,
          meta: { isDependencyTask: true, worktreeRecommended: true, forwardOnly: true },
        },
        null,
        2,
      )
    }

    // ——— Jev (System One choice) — после детерминированных правил, до эвристики ———
    // Не-enum/unknown/conf<0.5/не-ok/исключение — молча дальше в эвристику
    const sysKey = process.env.OPENCODE_API_KEY || process.env.JEV_API_KEY;
    if (sysKey) { try {
      const state = [`Задача: ${input.title}`, input.desc, `Сложность: ${input.level} (score ${input.score}), файлов: ${input.files}, зависимостей: ${input.deps}, тип: ${input.type}, unknowns: ${input.unknowns}, риск: ${input.risk_level} (${input.risk_score}/8)`].filter(s => s && s.trim()).join("\n");
      const res = await fetch("https://opencode.ai/inference/systemone/v1/systemone", { method:"POST", headers:{"Content-Type":"application/json", Authorization:`Bearer ${sysKey}`}, body: JSON.stringify({ model:"jev-1.13-free", state, questions:{
        builder:{type:"choice", instructions:"Какой исполнитель должен делать задачу?", criteria:{
          "build-fast":"мелкая определённая задача: 1-2 файла, низкая сложность и риск, без зависимостей",
          "build-smart":"сложная задача: интеграция, много файлов, зависимости, высокий риск — вдумчивая работа с проверками",
          "devops":"инфраструктура и деплой: docker, compose, сети, порты, окружения dev/prod, CI/CD-скрипты",
          "build":"не удалось определить подходящего исполнителя",
          "unknown":"задача непонятна, данных недостаточно"}},
        needs_tunnel:{type:"noul", instructions:"Просит ли задача явно показать результат через публичную preview-ссылку (tunnel/preview)?"}}}) });
      if (res.ok) { const j = await res.json(); const b = j && j.answers && j.answers.builder;
        if (b && ["build-fast","build-smart","devops","build"].indexOf(b.choice) !== -1 && b.choice !== "unknown") {
          const conf = (typeof b.confidence === "number") ? b.confidence : 0.85;
          const t = j.answers && j.answers.needs_tunnel;
          const tun = (t && typeof t.noul === "number") ? t.noul >= 0.5 : needsTunnelHeuristic.needs;
          if (conf >= 0.5) return JSON.stringify({builder:b.choice, confidence:conf, reason:"jev choice "+b.choice+" ("+conf+")", provider:"jev", needs_tunnel:tun, tunnel_reason: tun ? "jev: preview запрошен" : needsTunnelHeuristic.reason, input}, null, 2); } }
    } catch {} }

    if (isInsufficient) {
      return JSON.stringify({ builder: "build", confidence: 0.4, reason: "недостаточно данных для классификации — fallback к build по умолчанию", provider: "heuristic", needs_tunnel: needsTunnelHeuristic.needs, tunnel_reason: needsTunnelHeuristic.reason, input }, null, 2)
    }

    const isHighRisk = input.risk_level === "high" || (input.risk_score ?? 0) >= 6
    if (isHighRisk) {
      return JSON.stringify({ builder: "build-smart", confidence: 0.92, reason: "risk high → spec-first", provider: "heuristic", needs_tunnel: needsTunnelHeuristic.needs, tunnel_reason: needsTunnelHeuristic.reason, input }, null, 2)
    }
    // trivial gate: мелочь любого типа (add/update/delete) — не только создание.
    // Раньше требовался строго type=add, поэтому «поменяй строку» (update) всегда
    // уходило в smart. Безопасно: build-fast сам эскалирует (>3 файлов, deps, инфра).
    const isTrivial =
      input.level === "low" &&
      input.risk_level === "low" &&
      (input.files ?? 0) <= 2 &&
      (input.deps ?? 0) === 0 &&
      (input.unknowns ?? 0) <= 1 &&
      ["add", "update", "delete"].includes(input.type)
    if (isTrivial) {
      return JSON.stringify({ builder: "build-fast", confidence: 0.9, reason: "trivial: low/low, ≤2 files, add/update/delete, no deps, certain", provider: "heuristic", needs_tunnel: needsTunnelHeuristic.needs, tunnel_reason: needsTunnelHeuristic.reason, input }, null, 2)
    }
    // borderline: low на 3 файлах — в пределах допуска fast (он сам эскалирует при >3),
    // но с hint проверить скоуп; medium как раньше.
    if (input.level === "low" && input.risk_level === "low" && (input.files ?? 0) === 3 && (input.deps ?? 0) === 0 && (input.unknowns ?? 0) <= 1) {
      return JSON.stringify({ builder: "build-fast", confidence: 0.65, reason: "borderline low on 3 files → fast with hint check scope", provider: "heuristic", needs_tunnel: needsTunnelHeuristic.needs, tunnel_reason: needsTunnelHeuristic.reason, input, hint: "быстро, но проверь что затронуто ровно 3 файла" }, null, 2)
    }
    if (input.level === "medium" && input.risk_level === "low" && (input.files ?? 0) <= 2) {
      if ((input.unknowns ?? 0) >= 2) {
        return JSON.stringify({ builder: "build", confidence: 0.45, reason: "borderline medium с высокой неопределённостью — fallback к build", provider: "heuristic", needs_tunnel: needsTunnelHeuristic.needs, tunnel_reason: needsTunnelHeuristic.reason, input }, null, 2)
      }
      return JSON.stringify({ builder: "build-fast", confidence: 0.6, reason: "borderline medium → fast with hint check API", provider: "heuristic", needs_tunnel: needsTunnelHeuristic.needs, tunnel_reason: needsTunnelHeuristic.reason, input, hint: "быстро, но проверь API" }, null, 2)
    }
    if ((input.unknowns ?? 0) >= 3) {
      return JSON.stringify({ builder: "build", confidence: 0.4, reason: "высокая неопределённость — fallback к build по умолчанию", provider: "heuristic", needs_tunnel: needsTunnelHeuristic.needs, tunnel_reason: needsTunnelHeuristic.reason, input }, null, 2)
    }
    return JSON.stringify({ builder: "build-smart", confidence: 0.75, reason: "medium/high complexity or deps/type update/decompose", provider: "heuristic", needs_tunnel: needsTunnelHeuristic.needs, tunnel_reason: needsTunnelHeuristic.reason, input }, null, 2)
  },
}
