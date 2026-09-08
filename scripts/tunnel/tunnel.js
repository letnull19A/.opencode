#!/usr/bin/env node
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const https = require('https');
const os = require('os');
const path = require('path');

const DEFAULT_NAME = 'default';
const DEFAULT_TTL = 3600;
const START_TIMEOUT_MS = 25000;
const POLL_INTERVAL_MS = 250;
const KILL_GRACE_MS = 5000;
const KILL_FINAL_MS = 1000;
const IP_TIMEOUT_MS = 4000;
const IPV4_RE = /^\d{1,3}(\.\d{1,3}){3}$/;
const NAME_RE = /^[A-Za-z0-9._-]+$/;

const STATE_DIR = process.env.OPENCODE_TUNNEL_STATE_DIR
  || path.join(os.homedir(), '.local', 'state', 'opencode-tunnel');

const USAGE = [
  'Usage:',
  '  tunnel.js start --port <port> [--name <name>] [--ttl <seconds>]',
  '  tunnel.js restart [--port <port>] [--name <name>] [--ttl <seconds>]',
  '  tunnel.js kill [--name <name>] [--all]',
  '  tunnel.js status [--name <name>]',
  '  tunnel.js url [--name <name>]',
].join('\n');

const COMMAND_KEYS = {
  start: ['port', 'name', 'ttl'],
  restart: ['port', 'name', 'ttl'],
  kill: ['name', 'all'],
  status: ['name'],
  url: ['name'],
  _run: ['name', 'port', 'ttl'],
};

class UsageError extends Error {}

function statePath(name) {
  return path.join(STATE_DIR, `${name}.json`);
}

function logFile(name) {
  return path.join(STATE_DIR, `${name}.log`);
}

function ensureStateDir() {
  fs.mkdirSync(STATE_DIR, { recursive: true });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code !== 'ESRCH';
  }
}

function parseName(value) {
  const name = value || DEFAULT_NAME;
  if (!NAME_RE.test(name)) {
    throw new UsageError(`Invalid tunnel name: ${name} (allowed: letters, digits, . _ -)`);
  }
  return name;
}

function parsePort(value, { required = false } = {}) {
  if (value === undefined) {
    if (required) {
      throw new UsageError('Missing required option: --port <port>');
    }
    return undefined;
  }
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new UsageError(`Invalid port: ${value}`);
  }
  return port;
}

function parseTtl(value) {
  if (value === undefined) {
    return DEFAULT_TTL;
  }
  const ttl = Number(value);
  if (!Number.isInteger(ttl) || ttl < 1) {
    throw new UsageError(`Invalid ttl: ${value}`);
  }
  return ttl;
}

function readRecord(name) {
  try {
    return JSON.parse(fs.readFileSync(statePath(name), 'utf8'));
  } catch {
    return null;
  }
}

function deleteStateFile(name) {
  try {
    fs.rmSync(statePath(name), { force: true });
  } catch {}
}

function isLive(rec) {
  return Boolean(
    rec &&
    Number.isInteger(rec.pid) &&
    Number.isFinite(rec.expiresAt) &&
    pidAlive(rec.pid) &&
    Date.now() <= rec.expiresAt
  );
}

function listRecordNames() {
  try {
    return fs
      .readdirSync(STATE_DIR)
      .filter((file) => file.endsWith('.json'))
      .map((file) => file.slice(0, -'.json'.length));
  } catch {
    return [];
  }
}

function reapStale() {
  for (const name of listRecordNames()) {
    const rec = readRecord(name);
    const usable = rec && Number.isInteger(rec.pid) && Number.isFinite(rec.expiresAt);
    if (!usable || !isLive(rec)) {
      if (usable && pidAlive(rec.pid)) {
        try {
          process.kill(rec.pid, 'SIGTERM');
        } catch {}
      }
      deleteStateFile(name);
    }
  }
}

function printInfo(rec) {
  console.log(`TUNNEL_NAME=${rec.name}`);
  console.log(`PORT=${rec.port}`);
  console.log(`PREVIEW_URL=${rec.url}`);
  console.log(`PUBLIC_IP=${rec.publicIp || ''}`);
  console.log(`EXPIRES_AT=${new Date(rec.expiresAt).toISOString()}`);
}

function printReminderHint(rec) {
  console.error(
    `Note: the first visit to ${rec.url} shows a loca.lt reminder page; ` +
      `the tunnel password is the PUBLIC_IP printed above (${rec.publicIp || 'unknown'}).`
  );
}

async function waitPidExit(pid, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!pidAlive(pid)) {
      return true;
    }
    await sleep(100);
  }
  return !pidAlive(pid);
}

async function killTunnel(name) {
  const rec = readRecord(name);
  const pid = rec && Number.isInteger(rec.pid) ? rec.pid : null;
  const alive = pid !== null && pidAlive(pid);
  if (alive) {
    try {
      process.kill(pid, 'SIGTERM');
    } catch {}
    let exited = await waitPidExit(pid, KILL_GRACE_MS);
    if (!exited) {
      try {
        process.kill(pid, 'SIGKILL');
      } catch {}
      await waitPidExit(pid, KILL_FINAL_MS);
    }
  }
  deleteStateFile(name);
  return alive;
}

function spawnSupervisor(name, port, ttl) {
  const scriptPath = path.resolve(__filename);
  ensureStateDir();
  const logFd = fs.openSync(logFile(name), 'a');
  let child;
  try {
    child = spawn(
      process.execPath,
      [scriptPath, '_run', '--name', name, '--port', String(port), '--ttl', String(ttl)],
      { detached: true, stdio: ['ignore', logFd, logFd] }
    );
  } finally {
    try {
      fs.closeSync(logFd);
    } catch {}
  }
  child.unref();
  return child;
}

async function spawnSupervisorAndAwait(name, port, ttl) {
  const child = spawnSupervisor(name, port, ttl);
  let spawnError = null;
  child.on('error', (err) => {
    spawnError = err;
  });

  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (spawnError) {
      break;
    }
    if (child.exitCode !== null || child.signalCode !== null) {
      break;
    }
    const rec = readRecord(name);
    if (rec && rec.url) {
      printInfo(rec);
      printReminderHint(rec);
      return 0;
    }
    await sleep(POLL_INTERVAL_MS);
  }

  const rec = readRecord(name);
  if (rec && rec.url) {
    printInfo(rec);
    printReminderHint(rec);
    return 0;
  }

  console.error(
    `ERROR=tunnel_start_timeout MESSAGE="no state file with url after ${Math.round(
      START_TIMEOUT_MS / 1000
    )}s" LOG=${logFile(name)}`
  );
  if (child.pid && child.exitCode === null && child.signalCode === null) {
    try {
      process.kill(child.pid, 'SIGTERM');
    } catch {}
  }
  return 1;
}

async function cmdStart(args) {
  const name = parseName(args.name);
  const existing = readRecord(name);
  if (isLive(existing) && existing.url) {
    printInfo(existing);
    printReminderHint(existing);
    return 0;
  }
  const port = parsePort(args.port, { required: true });
  const ttl = parseTtl(args.ttl);
  return spawnSupervisorAndAwait(name, port, ttl);
}

async function cmdRestart(args) {
  const name = parseName(args.name);
  const previous = readRecord(name);
  if (previous) {
    const killed = await killTunnel(name);
    if (killed) {
      console.log(`KILLED=${name}`);
    }
  }
  const port =
    args.port !== undefined
      ? parsePort(args.port)
      : previous && Number.isInteger(previous.port)
        ? previous.port
        : undefined;
  if (port === undefined) {
    throw new UsageError('Missing required option: --port <port> (no previous record for this name)');
  }
  const ttl = parseTtl(args.ttl);
  return spawnSupervisorAndAwait(name, port, ttl);
}

async function cmdKill(args) {
  const names = args.all ? listRecordNames() : [parseName(args.name)];
  for (const name of names) {
    const killed = await killTunnel(name);
    console.log(`${killed ? 'KILLED' : 'NOT_RUNNING'}=${name}`);
  }
  return 0;
}

function statusLine(rec) {
  const ttlLeft = Math.max(0, Math.ceil((rec.expiresAt - Date.now()) / 1000));
  return `TUNNEL_NAME=${rec.name} PORT=${rec.port} PREVIEW_URL=${rec.url} PUBLIC_IP=${
    rec.publicIp || ''
  } TTL_LEFT_S=${ttlLeft}`;
}

function cmdStatus(args) {
  let candidates;
  if (args.name !== undefined) {
    candidates = [readRecord(parseName(args.name))];
  } else {
    candidates = listRecordNames().map((name) => readRecord(name));
  }
  const live = candidates.filter(isLive);
  if (live.length === 0) {
    console.log('ACTIVE_TUNNELS=0');
    return 0;
  }
  for (const rec of live) {
    console.log(statusLine(rec));
  }
  return 0;
}

function cmdUrl(args) {
  const name = parseName(args.name);
  const rec = readRecord(name);
  if (isLive(rec) && rec.url) {
    console.log(`PREVIEW_URL=${rec.url}`);
    return 0;
  }
  console.error(`No active tunnel named "${name}".`);
  return 1;
}

function fetchPublicIp() {
  return new Promise((resolve) => {
    let settled = false;
    const done = (ip) => {
      if (!settled) {
        settled = true;
        resolve(ip);
      }
    };
    const req = https.get('https://api.ipify.org', (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        data += chunk;
        if (data.length > 256) {
          req.destroy();
        }
      });
      res.on('end', () => {
        const ip = data.trim();
        done(
          IPV4_RE.test(ip) && ip.split('.').every((octet) => Number(octet) <= 255) ? ip : ''
        );
      });
      res.on('error', () => done(''));
    });
    req.setTimeout(IP_TIMEOUT_MS, () => {
      req.destroy();
      done('');
    });
    req.on('error', () => done(''));
  });
}

async function cmdRun(args) {
  const localtunnel = require('localtunnel');
  const name = parseName(args.name);
  const port = parsePort(args.port, { required: true });
  const ttl = parseTtl(args.ttl);

  let tunnel;
  try {
    tunnel = await localtunnel({ port, local_host: 'localhost' });
  } catch (err) {
    console.error(
      `[tunnel:${name}] failed to open tunnel: ${err && err.message ? err.message : err}`
    );
    deleteStateFile(name);
    process.exit(1);
  }

  const url = tunnel.url;
  if (!url) {
    console.error(`[tunnel:${name}] tunnel opened without a url`);
    try {
      tunnel.close();
    } catch {}
    deleteStateFile(name);
    process.exit(1);
  }

  const publicIp = await fetchPublicIp();
  const record = {
    name,
    port,
    pid: process.pid,
    url,
    startedAt: Date.now(),
    expiresAt: Date.now() + ttl * 1000,
    publicIp,
  };
  try {
    fs.writeFileSync(statePath(name), JSON.stringify(record, null, 2));
  } catch (err) {
    console.error(
      `[tunnel:${name}] failed to write state file: ${err && err.message ? err.message : err}`
    );
    try {
      tunnel.close();
    } catch {}
    deleteStateFile(name);
    process.exit(1);
  }

  const keepAlive = setInterval(() => {}, 60000);
  const ttlTimer = setTimeout(() => shutdown('ttl'), ttl * 1000);

  let shuttingDown = false;
  function shutdown(reason) {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    console.error(`[tunnel:${name}] shutting down (${reason})`);
    try {
      tunnel.close();
    } catch {}
    deleteStateFile(name);
    clearInterval(keepAlive);
    clearTimeout(ttlTimer);
    process.exit(0);
  }

  tunnel.on('close', () => shutdown('tunnel closed'));
  tunnel.on('error', (err) => {
    console.error(`[tunnel:${name}] error: ${err && err.message ? err.message : err}`);
  });
  process.on('SIGTERM', () => shutdown('sigterm'));
  process.on('SIGINT', () => shutdown('sigint'));

  await new Promise(() => {});
}

function parseArgs(cmd, argv) {
  const allowed = COMMAND_KEYS[cmd];
  if (!allowed) {
    return {};
  }
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!token.startsWith('--')) {
      throw new UsageError(`Unexpected argument: ${token}`);
    }
    const key = token.slice(2);
    if (!allowed.includes(key)) {
      throw new UsageError(`Unknown option: --${key}`);
    }
    if (key === 'all') {
      args.all = true;
      continue;
    }
    const value = argv[++i];
    if (value === undefined) {
      throw new UsageError(`Missing value for --${key}`);
    }
    args[key] = value;
  }
  return args;
}

async function main() {
  const argv = process.argv.slice(2);
  const cmd = argv.shift();
  const args = parseArgs(cmd, argv);
  ensureStateDir();
  reapStale();
  switch (cmd) {
    case 'start':
      return cmdStart(args);
    case 'restart':
      return cmdRestart(args);
    case 'kill':
      return cmdKill(args);
    case 'status':
      return cmdStatus(args);
    case 'url':
      return cmdUrl(args);
    case '_run':
      return cmdRun(args);
    default:
      if (!cmd) {
        throw new UsageError('Missing command');
      }
      throw new UsageError(`Unknown command: ${cmd}`);
  }
}

main()
  .then((code) => process.exit(code || 0))
  .catch((err) => {
    if (err instanceof UsageError) {
      console.error(err.message);
      console.error(USAGE);
      process.exit(1);
    }
    console.error(err && err.stack ? err.stack : String(err));
    process.exit(1);
  });
