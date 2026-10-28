// Added to the app by patch.py as its new entry point. Runs in the app's main
// process, injects inject.js into claude.ai pages, then starts the real app.
//
// Edits to config.json and inject.js apply live. The page saves picker choices
// by logging SAVE_PREFIX + JSON, which this file writes to config.json.
const { app, dialog, Notification } = require("electron");
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const DIR = __CLAUDE_COLORS_DIR__;
const CONFIG = path.join(DIR, "config.json");
const DUMP_REQUEST = path.join(DIR, ".dump-request");
const DUMP = path.join(os.homedir(), "Library/Logs/Claude/claude-colors-dom.html");
const NOTIFY_TEST = path.join(DIR, ".notify-test");
const NOTIFY_LOG = path.join(os.homedir(), "Library/Logs/Claude/claude-colors-notify.log");
const BOTH_OPEN = "Claude and Claude Colors share the same sessions, so running both makes them fight over each one.";
const SAVE_PREFIX = "__claude_colors_save__";
const isClaudePage = (url) => /^https:\/\/(preview\.)?claude\.ai\//.test(url);
const pages = new Set();
let icons = null;
// The page already shows its own saves, so re-running inject.js would only close the picker.
let lastSavedConfig = null;

// The original app, or any other copy: every main binary named Claude but this one.
function otherClaudePids() {
  return execFileSync("ps", ["-axo", "pid=,comm="], { encoding: "utf8" })
    .split("\n")
    .map((line) => line.trim().match(/^(\d+) (.*\/Contents\/MacOS\/Claude)$/))
    .filter((match) => match && match[2] !== process.execPath)
    .map((match) => Number(match[1]));
}

function quitOtherClaude(pids) {
  pids.forEach((pid) => process.kill(pid, "SIGTERM"));
  const deadline = Date.now() + 15000;
  while (otherClaudePids().length && Date.now() < deadline) execFileSync("sleep", ["0.5"]);
}

// Electron can't show its own dialogs before the app is ready, hence osascript.
function checkAtLaunch() {
  const pids = otherClaudePids();
  if (!pids.length) return;
  try {
    execFileSync("osascript", [
      "-e",
      `display dialog "Claude is already open. ${BOTH_OPEN}" with title "Claude Colors" ` +
        `buttons {"Cancel", "Quit Claude"} default button "Quit Claude" with icon caution`,
    ]);
  } catch {
    process.exit(0);
  }
  quitOtherClaude(pids);
}

const ignoredPids = new Set();
async function checkWhileRunning() {
  const pids = otherClaudePids().filter((pid) => !ignoredPids.has(pid));
  if (!pids.length) return;
  pids.forEach((pid) => ignoredPids.add(pid));
  const { response } = await dialog.showMessageBox({
    type: "warning",
    message: "Claude was opened too",
    detail: BOTH_OPEN,
    buttons: ["Quit Claude", "Ignore"],
    defaultId: 0,
  });
  if (response === 0) quitOtherClaude(pids);
}

function testNotification() {
  fs.rmSync(NOTIFY_TEST, { force: true });
  const log = (line) => fs.appendFileSync(NOTIFY_LOG, `${new Date().toISOString()} ${line}\n`);
  log(`supported=${Notification.isSupported()}`);
  const notification = new Notification({ title: "Claude Colors", body: "Notifications work." });
  notification.on("show", () => log("shown"));
  notification.on("failed", (_event, error) => log(`failed ${error}`));
  notification.show();
}

function inject(webContents) {
  try {
    icons ??= fs.readFileSync(path.join(DIR, "icons.json"), "utf8");
    const config = fs.readFileSync(CONFIG, "utf8");
    const source = fs.readFileSync(path.join(DIR, "inject.js"), "utf8");
    webContents
      .executeJavaScript(`(${source})({ config: ${config}, icons: ${icons} })`)
      .catch((err) => console.error("[claude-colors]", err));
  } catch (err) {
    console.error("[claude-colors]", err);
  }
}

function save({ name, project }) {
  const config = JSON.parse(fs.readFileSync(CONFIG, "utf8"));
  if (project) config.projects[name] = project;
  else delete config.projects[name];
  lastSavedConfig = JSON.stringify(config, null, 2) + "\n";
  fs.writeFileSync(CONFIG, lastSavedConfig);
}

function dump() {
  fs.rmSync(DUMP_REQUEST, { force: true });
  for (const webContents of pages) {
    webContents
      .executeJavaScript("document.body.outerHTML")
      .then((html) => fs.writeFileSync(DUMP, html))
      .catch(() => {});
  }
}

app.on("web-contents-created", (_event, webContents) => {
  webContents.on("did-finish-load", () => {
    if (!isClaudePage(webContents.getURL())) return;
    pages.add(webContents);
    inject(webContents);
  });
  webContents.on("console-message", (event) => {
    if (!event.message.startsWith(SAVE_PREFIX)) return;
    try {
      save(JSON.parse(event.message.slice(SAVE_PREFIX.length)));
    } catch (err) {
      console.error("[claude-colors]", err);
    }
  });
  webContents.on("destroyed", () => pages.delete(webContents));
});

app.whenReady().then(() => {
  app.dock?.setIcon(path.join(process.resourcesPath, "claude-colors-icon.png"));
  if (fs.existsSync(DUMP_REQUEST)) setTimeout(dump, 15000);
  let pending = null;
  setInterval(checkWhileRunning, 30 * 1000);
  fs.watch(DIR, (_type, file) => {
    if (file === ".dump-request" && fs.existsSync(DUMP_REQUEST)) return dump();
    if (file === ".notify-test" && fs.existsSync(NOTIFY_TEST)) return testNotification();
    if (file !== "config.json" && file !== "inject.js") return;
    if (file === "config.json" && fs.readFileSync(CONFIG, "utf8") === lastSavedConfig) return;
    clearTimeout(pending);
    pending = setTimeout(() => pages.forEach(inject), 150);
  });
});

checkAtLaunch();
require("./index.pre.js");
