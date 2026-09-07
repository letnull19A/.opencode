import { readFile } from "node:fs/promises";
import path from "node:path";

// Requires TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env
export async function send({ runDir, zipPath }) {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  const chatId = process.env.TELEGRAM_CHAT_ID;
  if (!token || !chatId) throw new Error("TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set");

  const buf = await readFile(zipPath);
  const form = new FormData();
  form.append("chat_id", chatId);
  form.append("caption", `Adaptive screenshot report — ${path.basename(runDir)}`);
  form.append("document", new Blob([buf]), "report.zip");

  const res = await fetch(`https://api.telegram.org/bot${token}/sendDocument`, {
    method: "POST",
    body: form,
  });
  if (!res.ok) throw new Error(`Telegram API error: ${res.status} ${await res.text()}`);
  console.log("Sent to Telegram.");
}
