import path from "node:path";
import { createWriteStream } from "node:fs";
import archiver from "archiver";
import "dotenv/config";

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
  console.error("Missing --run-dir");
  process.exit(1);
}

const method = args["method"] || process.env.DELIVERY_METHOD || "local";
const zipPath = path.join(runDir, "report.zip");

// 1. zip the whole run dir (screenshots + report.html + manifest.json)
await new Promise((resolve, reject) => {
  const output = createWriteStream(zipPath);
  const archive = archiver("zip", { zlib: { level: 9 } });
  output.on("close", resolve);
  archive.on("error", reject);
  archive.pipe(output);
  archive.directory(runDir, false, (entry) => (entry.name === "report.zip" ? false : entry));
  archive.finalize();
});
console.log(`Archive: ${zipPath}`);

// 2. hand off to the chosen adapter. Add new adapters under ./adapters/ and
//    register them here — nothing else in the pipeline needs to change.
const adapters = {
  local: () => import("./adapters/local.js"),
  telegram: () => import("./adapters/telegram.js"),
  webhook: () => import("./adapters/webhook.js"),
  s3: () => import("./adapters/s3.js"),
};

if (!adapters[method]) {
  console.error(`Unknown DELIVERY_METHOD "${method}". Available: ${Object.keys(adapters).join(", ")}`);
  process.exit(1);
}

const mod = await adapters[method]();
await mod.send({ runDir, zipPath });
