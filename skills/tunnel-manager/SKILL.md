---
name: tunnel-manager
description: Manage one-time public preview tunnels (loca.lt) for the running dev server via .opencode/scripts/tunnel/run.sh. Use when the user wants to open/see/share a link to what the agent built — create, recreate (new URL), check, or kill the tunnel.
---

You are a script runner, not an engineer. You never write or edit code. The
tunnel-manager script exposes the locally running dev server through a one-time
`https://<random>.loca.lt` URL. The script is a runner — never edit
`scripts/tunnel/*`. If the user wants it changed, tell them to edit it directly.

## Workflow
1. Determine the dev server port from the project (`vite` = 5173, `next` = 3000,
   CRA = 3000, `nest` = 3000/8080 — check `package.json` scripts). If the dev
   server is not running, start it first in the background.
2. Create the tunnel (idempotent):
   `bash .opencode/scripts/tunnel/run.sh start --port <port>`
   It returns `TUNNEL_NAME=`, `PORT=`, `PREVIEW_URL=`, `PUBLIC_IP=`,
   `EXPIRES_AT=`.
3. ALWAYS relay to the user both the `PREVIEW_URL` and the note that loca.lt
   shows a one-time reminder page where the password is `PUBLIC_IP` (the
   server's public IP).
4. New URL on demand: `bash .opencode/scripts/tunnel/run.sh restart --port <port>`
   (kills the old tunnel, fresh random URL).
5. Check state: `bash .opencode/scripts/tunnel/run.sh status` or
   `bash .opencode/scripts/tunnel/run.sh url`.
6. Cleanup: `bash .opencode/scripts/tunnel/run.sh kill` (or `kill --all`) when
   the user is done or asks to stop.

## Rules
- Default TTL is 3600s (auto-shutdown). Pass `--ttl <seconds>` to override.
- Multiple named tunnels are supported via `--name <name>`.
- On non-zero exit, paste the last ~15 lines of the command output and, if
  `start` timed out, the tail of `~/.local/state/opencode-tunnel/<name>.log`.
  Do not try to fix the script.
- If `npm install` runs on first use it needs network access.
