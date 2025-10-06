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
cat /opt/camera-watch/watchdog.js   # Code reinkopieren
// watchdog.js
// Checks localhost:3000/thermal. If request fails/empty OR payload is unchanged
// for STALE_WINDOW_SEC, dump pm2 logs and restart the given apps.

const { execFile, exec } = require("child_process");
const { mkdirSync, appendFileSync } = require("fs");
const { join } = require("path");
const crypto = require("crypto");

const URL = process.env.WATCH_URL || "http://127.0.0.1:3000/thermal/frame/image/jpg";
const INTERVAL_MS = parseInt(process.env.WATCH_INTERVAL_MS || "5000", 10);
const FAILURE_THRESHOLD = parseInt(process.env.FAILURE_THRESHOLD || "2", 10);
const STALE_WINDOW_SEC = parseInt(process.env.STALE_WINDOW_SEC || "10", 10);
const LOG_DIR = process.env.WATCH_LOG_DIR || "/var/log/camera-watch";
const APPS = (process.env.WATCH_PM2_APPS || "Demo_linux_so,index, ffmpeg-screenshot-loop").split(",");

mkdirSync(LOG_DIR, { recursive: true });

let consecutiveFails = 0;
let healing = false;

// Staleness tracking
let lastDigest = null;           // sha1 of last successful payload
let lastChangeAt = Date.now();   // timestamp when payload last changed

function nowStamp() {
  const d = new Date();
  const pad = n => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}_${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}`;
}

function curlGet(url, timeoutSec = 3) {
  return new Promise((resolve, reject) => {
    execFile(
      "curl",
      ["-fsS", "--max-time", String(timeoutSec), url],
      { timeout: (timeoutSec + 1) * 1000, encoding: "utf8" },
      (err, stdout) => {
        if (err) return reject(err);
        const body = (stdout || "").trim();
        if (!body) return reject(new Error("Empty response"));
        resolve(body);
      }
    );
  });
}

function digest(s) {
  return crypto.createHash("sha1").update(s).digest("hex");
}

function pm2LogsOnce(app, lines = 800, timeoutSec = 6) {
  return new Promise((resolve) => {
    const cmd = `timeout ${timeoutSec}s pm2 logs ${app} --lines ${lines}`;
    exec(cmd, { encoding: "utf8", maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve(`\n===== pm2 logs ${app} (last ${lines}) =====\n${stdout || ""}\n${stderr || ""}`);
    });
  });
}

async function collectAndSaveLogs() {
  const ts = nowStamp();
  const outPath = join(LOG_DIR, `incident_${ts}.log`);
  try {
    appendFileSync(outPath, `# Incident @ ${ts}\nURL: ${URL}\n` +
      `INTERVAL_MS=${INTERVAL_MS} STALE_WINDOW_SEC=${STALE_WINDOW_SEC}\n\n`);
    for (const app of APPS) {
      const chunk = await pm2LogsOnce(app, 800, 6);
      appendFileSync(outPath, chunk);
    }
    appendFileSync(outPath, "\n===== pm2 list =====\n");
    await new Promise(r => exec("pm2 list", { encoding: "utf8" }, (_, stdout) => { appendFileSync(outPath, stdout || ""); r(); }));
    return outPath;
  } catch {
    return outPath;
  }
}

function pm2Restart(app) {
  return new Promise((resolve) => {
    exec(`pm2 restart ${app}`, { encoding: "utf8" }, (_, stdout, stderr) => {
      resolve((stdout || "") + (stderr || ""));
    });
  });
}

async function heal(reason = "unknown") {
  if (healing) return;
  healing = true;
  try {
    const path = await collectAndSaveLogs();
    for (const app of APPS) {
      await pm2Restart(app);
    }
    console.log(`[watchdog] Healed after ${reason}. Logged to ${path}. Restarted: ${APPS.join(", ")}`);
  } finally {
    // cooldown to avoid loops
    setTimeout(() => { healing = false; }, 10000);
    // reset failure counter; staleness will re-arm on next ticks
    consecutiveFails = 0;
    lastDigest = null;         // force fresh baseline after restart
    lastChangeAt = Date.now();
  }
}

async function tick() {
  if (healing) return;

  try {
    const body = await curlGet(URL, 3);
    // On successful fetch: staleness check
    const d = digest(body);

    if (lastDigest === null) {
      lastDigest = d;
      lastChangeAt = Date.now();
    } else if (d !== lastDigest) {
      // payload changed -> reset staleness timer
      lastDigest = d;
      lastChangeAt = Date.now();
    } else {
      // payload unchanged
      const staleForMs = Date.now() - lastChangeAt;
      if (staleForMs >= STALE_WINDOW_SEC * 1000) {
        return heal(`stale payload for >= ${STALE_WINDOW_SEC}s`);
      }
    }

    // success -> reset network failures
    consecutiveFails = 0;
  } catch (e) {
    // request failed or empty
    consecutiveFails += 1;
    if (consecutiveFails >= FAILURE_THRESHOLD) {
      return heal(`request failure x${consecutiveFails}`);
    }
  }
}

console.log(`[watchdog] Monitoring ${URL} every ${INTERVAL_MS}ms. ` +
            `Stale window: ${STALE_WINDOW_SEC}s. PM2 apps: ${APPS.join(", ")}. Logs -> ${LOG_DIR}`);
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
