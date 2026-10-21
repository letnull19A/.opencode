import path from "path"
import fs from "fs"
export function resolveScript(scriptRel: string, context: unknown): { root: string; script: string } {
  const c = (context ?? {}) as Record<string, unknown>;
  const direct = c.worktree ?? c.directory ?? c.cwd;
  if (typeof direct !== "string" || !direct) throw new Error("[pack-tools] scripts root unresolved: передай worktree/directory в input тула");
  const abs = path.resolve(direct);
  const c1 = path.join(abs, ".opencode", "scripts", scriptRel);
  if (fs.existsSync(c1)) return { root: abs, script: c1 };
  const c2 = path.join(abs, "scripts", scriptRel);
  if (fs.existsSync(c2)) return { root: abs, script: c2 };
  throw new Error(`[pack-tools] script not found: ${scriptRel} (root ${abs})`);
}
