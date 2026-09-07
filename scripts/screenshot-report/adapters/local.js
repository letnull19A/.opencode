// Fallback adapter — used while you haven't picked a real destination yet.
// Just confirms where the finished archive/report sits.
export async function send({ runDir, zipPath }) {
  console.log(`No DELIVERY_METHOD configured — report left on disk.`);
  console.log(`  HTML : ${runDir}/report.html`);
  console.log(`  ZIP  : ${zipPath}`);
}
