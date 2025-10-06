#!/usr/bin/env bash
set -e

echo "[+] Installing Camera Watchdog..."

# ---- CONFIG ----
INSTALL_DIR="/opt/camera-watch"
LOG_DIR="/var/log/camera-watch"
SCRIPT_FILE="$INSTALL_DIR/watchdog.js"
SERVICE_NAME="camera-watchdog"
WATCH_URL="http://127.0.0.1:3000/thermal"
PM2_APPS="Demo_linux_so,index"
INTERVAL_MS=5000
FAILURE_THRESHOLD=2

# ---- DEPENDENCIES ----
if ! command -v curl &>/dev/null; then
  echo "[+] Installing curl..."
  sudo apt-get update -y && sudo apt-get install -y curl
fi

if ! command -v pm2 &>/dev/null; then
  echo "[+] Installing PM2..."
  sudo npm install -g pm2
fi

# ---- INSTALL SCRIPT ----
sudo mkdir -p "$INSTALL_DIR" "$LOG_DIR"
sudo chown -R "$USER":"$USER" "$INSTALL_DIR" "$LOG_DIR"

cat > "$SCRIPT_FILE" <<"EOF"
// watchdog.js - auto-installed
const { execFile, exec } = require("child_process");
const { mkdirSync, appendFileSync } = require("fs");
const { join } = require("path");

const URL = process.env.WATCH_URL || "http://127.0.0.1:3000/thermal";
const INTERVAL_MS = parseInt(process.env.WATCH_INTERVAL_MS || "5000", 10);
const FAILURE_THRESHOLD = parseInt(process.env.FAILURE_THRESHOLD || "2", 10);
const LOG_DIR = process.env.WATCH_LOG_DIR || "/var/log/camera-watch";
const APPS = (process.env.WATCH_PM2_APPS || "Demo_linux_so,index").split(",");

mkdirSync(LOG_DIR, { recursive: true });

let consecutiveFails = 0;
let healing = false;

function nowStamp() {
  const d = new Date();
  const pad = n => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}_${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`;
}

function curlGet(url, timeoutSec = 3) {
  return new Promise((resolve, reject) => {
    execFile("curl", ["-fsS", "--max-time", String(timeoutSec), url], { timeout: (timeoutSec + 1) * 1000, encoding: "utf8" }, (err, stdout) => {
      if (err) return reject(err);
      if (!stdout || !stdout.trim()) return reject(new Error("Empty response"));
      resolve(stdout);
    });
  });
}

function pm2LogsOnce(app, lines = 500, timeoutSec = 5) {
  return new Promise((resolve) => {
    const cmd = `timeout ${timeoutSec}s pm2 logs ${app} --lines ${lines}`;
    exec(cmd, { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve(`\n===== pm2 logs ${app} =====\n${stdout || ""}\n${stderr || ""}`);
    });
  });
}

async function collectAndSaveLogs() {
  const ts = nowStamp();
  const outPath = join(LOG_DIR, `incident_${ts}.log`);
  appendFileSync(outPath, `# Incident @ ${ts}\nURL: ${URL}\n\n`);
  for (const app of APPS) {
    const chunk = await pm2LogsOnce(app, 800, 6);
    appendFileSync(outPath, chunk);
  }
  appendFileSync(outPath, "\n===== pm2 list =====\n");
  await new Promise(r => exec("pm2 list", { encoding: "utf8" }, (_, stdout) => { appendFileSync(outPath, stdout || ""); r(); }));
  return outPath;
}

function pm2Restart(app) {
  return new Promise((resolve) => {
    exec(`pm2 restart ${app}`, { encoding: "utf8" }, (_, stdout, stderr) => {
      resolve((stdout || "") + (stderr || ""));
    });
  });
}

async function heal() {
  if (healing) return;
  healing = true;
  try {
    const path = await collectAndSaveLogs();
    for (const app of APPS) await pm2Restart(app);
    setTimeout(() => { healing = false; }, 10000);
    console.log(`[watchdog] Logged to ${path}. Restarted: ${APPS.join(", ")}`);
  } catch {
    healing = false;
  }
}

async function tick() {
  if (healing) return;
  try {
    await curlGet(URL, 3);
    consecutiveFails = 0;
  } catch {
    consecutiveFails += 1;
    if (consecutiveFails >= FAILURE_THRESHOLD) {
      consecutiveFails = 0;
      heal();
    }
  }
}

console.log(`[watchdog] Monitoring ${URL} every ${INTERVAL_MS}ms.`);
setInterval(tick, INTERVAL_MS);
EOF

# ---- START VIA PM2 ----
cd "$INSTALL_DIR"
pm2 start "$SCRIPT_FILE" --name "$SERVICE_NAME" \
  --env WATCH_URL="$WATCH_URL" \
  --env WATCH_PM2_APPS="$PM2_APPS" \
  --env WATCH_LOG_DIR="$LOG_DIR" \
  --env WATCH_INTERVAL_MS="$INTERVAL_MS" \
  --env FAILURE_THRESHOLD="$FAILURE_THRESHOLD"

pm2 save
pm2 startup | bash

echo "[+] Done! Watchdog running via PM2 (${SERVICE_NAME})"
