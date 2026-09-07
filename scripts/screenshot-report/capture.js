import { chromium, devices } from "playwright";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import path from "node:path";
import "dotenv/config";
import { VIEWPORTS } from "./config/viewports.js";

// ---- args -------------------------------------------------------------
// node capture.js --base-url https://app.example.com --pages ./pages.json --out ./out
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
const BASE_URL = args["base-url"] || process.env.BASE_URL;
const PAGES_FILE = args["pages"] || process.env.PAGES_FILE || "./pages.example.json";
const OUT_ROOT = args["out"] || "./out";
const FULL_PAGE = args["full-page"] !== "false"; // default true
const TIMEOUT_MS = Number(args["timeout"] || 30000);

if (!BASE_URL) {
  console.error("Missing --base-url (or BASE_URL env var). Example: --base-url https://staging.myapp.com");
  process.exit(1);
}

const pages = JSON.parse(await readFile(PAGES_FILE, "utf-8"));
const runId = new Date().toISOString().replace(/[:.]/g, "-");
const runDir = path.join(OUT_ROOT, runId);
await mkdir(runDir, { recursive: true });

const browser = await chromium.launch({ headless: true });
const manifest = { baseUrl: BASE_URL, runId, viewports: [], pages: pages.map((p) => p.id) };

for (const vp of VIEWPORTS) {
  const contextOptions =
    vp.kind === "device"
      ? { ...devices[vp.device] }
      : {
          viewport: { width: vp.width, height: vp.height },
          deviceScaleFactor: vp.deviceScaleFactor || 1,
        };

  const context = await browser.newContext(contextOptions);
  const page = await context.newPage();
  const vpDir = path.join(runDir, vp.id);
  await mkdir(vpDir, { recursive: true });

  for (const target of pages) {
    const url = new URL(target.path, BASE_URL).toString();
    const filePath = path.join(vpDir, `${target.id}.png`);
    try {
      await page.goto(url, { waitUntil: "networkidle", timeout: TIMEOUT_MS });
      // give lazy-loaded/animated content a moment to settle
      await page.waitForTimeout(300);
      await page.screenshot({ path: filePath, fullPage: FULL_PAGE });
      console.log(`OK   ${vp.id.padEnd(18)} ${target.id.padEnd(16)} -> ${filePath}`);
    } catch (err) {
      console.error(`FAIL ${vp.id.padEnd(18)} ${target.id.padEnd(16)} ${url}: ${err.message}`);
    }
  }

  await context.close();
  manifest.viewports.push({
    id: vp.id,
    label: vp.kind === "device" ? vp.device : `${vp.width}x${vp.height}`,
  });
}

await browser.close();
await writeFile(path.join(runDir, "manifest.json"), JSON.stringify(manifest, null, 2));
console.log(`\nRun dir: ${runDir}`);
// Print the run dir as the last line so the shell wrapper can capture it.
console.log(`RUN_DIR=${runDir}`);
