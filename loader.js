// Added to the app by patch.py as its new entry point. Runs in the app's main
// process, injects inject.js into claude.ai pages, then starts the real app.
//
// Edits to config.json and inject.js apply live. The page saves picker choices
// by logging SAVE_PREFIX + JSON, which this file writes to config.json.
const { app } = require("electron");
const fs = require("fs");
const path = require("path");
const os = require("os");

const DIR = __CLAUDE_COLORS_DIR__;
const CONFIG = path.join(DIR, "config.json");
const DUMP_REQUEST = path.join(DIR, ".dump-request");
const DUMP = path.join(os.homedir(), "Library/Logs/Claude/claude-colors-dom.html");
const SAVE_PREFIX = "__claude_colors_save__";
const isClaudePage = (url) => /^https:\/\/(preview\.)?claude\.ai\//.test(url);
const pages = new Set();
let icons = null;
// The page already shows its own saves, so re-running inject.js would only close the picker.
let lastSavedConfig = null;

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
  if (fs.existsSync(DUMP_REQUEST)) setTimeout(dump, 15000);
  let pending = null;
  fs.watch(DIR, (_type, file) => {
    if (file === ".dump-request" && fs.existsSync(DUMP_REQUEST)) return dump();
    if (file !== "config.json" && file !== "inject.js") return;
    if (file === "config.json" && fs.readFileSync(CONFIG, "utf8") === lastSavedConfig) return;
    clearTimeout(pending);
    pending = setTimeout(() => pages.forEach(inject), 150);
  });
});

require("./index.pre.js");
