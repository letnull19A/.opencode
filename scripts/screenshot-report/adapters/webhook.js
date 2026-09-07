import { readFile } from "node:fs/promises";

// Requires REPORT_WEBHOOK_URL in .env. Sends the zip as multipart/form-data.
export async function send({ runDir, zipPath }) {
  const url = process.env.REPORT_WEBHOOK_URL;
  if (!url) throw new Error("REPORT_WEBHOOK_URL not set");

  const buf = await readFile(zipPath);
  const form = new FormData();
  form.append("runDir", runDir);
  form.append("file", new Blob([buf]), "report.zip");

  const res = await fetch(url, { method: "POST", body: form });
  if (!res.ok) throw new Error(`Webhook error: ${res.status} ${await res.text()}`);
  console.log(`Sent to webhook ${url}`);
}
