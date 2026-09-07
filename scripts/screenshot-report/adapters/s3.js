import { readFile } from "node:fs/promises";
import path from "node:path";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

// Requires: S3_BUCKET, S3_REGION, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY
// Optional: S3_ENDPOINT (for R2/MinIO/other S3-compatible storage)
export async function send({ runDir, zipPath }) {
  const {
    S3_BUCKET,
    S3_REGION = "auto",
    S3_ACCESS_KEY_ID,
    S3_SECRET_ACCESS_KEY,
    S3_ENDPOINT,
  } = process.env;
  if (!S3_BUCKET || !S3_ACCESS_KEY_ID || !S3_SECRET_ACCESS_KEY) {
    throw new Error("S3_BUCKET / S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY not set");
  }

  const client = new S3Client({
    region: S3_REGION,
    endpoint: S3_ENDPOINT,
    credentials: { accessKeyId: S3_ACCESS_KEY_ID, secretAccessKey: S3_SECRET_ACCESS_KEY },
  });

  const key = `reports/${path.basename(runDir)}.zip`;
  const body = await readFile(zipPath);
  await client.send(
    new PutObjectCommand({ Bucket: S3_BUCKET, Key: key, Body: body, ContentType: "application/zip" })
  );
  console.log(`Uploaded to s3://${S3_BUCKET}/${key}`);
}
