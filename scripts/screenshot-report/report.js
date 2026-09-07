import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const val = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
      args[key] = val;
    }
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const runDir = args["run-dir"];
if (!runDir) {
  console.error("Missing --run-dir (pass the RUN_DIR printed by capture.js)");
  process.exit(1);
}

const manifest = JSON.parse(await readFile(path.join(runDir, "manifest.json"), "utf-8"));

const rows = manifest.pages
  .map((pageId) => {
    const cells = manifest.viewports
      .map(
        (vp) => `
      <figure>
        <figcaption>${vp.label}</figcaption>
        <img loading="lazy" src="${vp.id}/${pageId}.png" alt="${pageId} @ ${vp.label}">
      </figure>`
      )
      .join("");
    return `<section><h2>${pageId}</h2><div class="row">${cells}</div></section>`;
  })
  .join("\n");

const html = `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<title>Adaptive report — ${manifest.baseUrl} — ${manifest.runId}</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 0; padding: 24px; background: #111; color: #eee; }
  h1 { font-size: 18px; opacity: .8; }
  h2 { font-size: 16px; margin: 32px 0 8px; }
  .row { display: flex; gap: 16px; overflow-x: auto; padding-bottom: 8px; }
  figure { margin: 0; flex: 0 0 auto; }
  figcaption { font-size: 12px; opacity: .6; margin-bottom: 4px; }
  img { max-height: 480px; border: 1px solid #333; border-radius: 4px; }
</style>
</head>
<body>
  <h1>${manifest.baseUrl} — ${manifest.runId}</h1>
  ${rows}
</body>
</html>`;

const outFile = path.join(runDir, "report.html");
await writeFile(outFile, html);
console.log(`Report: ${outFile}`);
