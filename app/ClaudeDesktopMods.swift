// Claude Desktop Mods app: turns the mods on or off, restarts Claude, and runs the
// mods each time Claude opens by typing the DevTools shortcuts (⌥⌘I, ⌘P, !cdm,
// Enter) in a DevTools window tucked off-screen, then closing it.
// Typing into Claude and moving its windows needs the Accessibility permission.
// Built into ~/Applications/Claude Desktop Mods.app by app/build.py.
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

let claudeBundleID = "com.anthropic.claudefordesktop"
let repoPath = Bundle.main.object(forInfoDictionaryKey: "CDMRepo") as? String ?? ""
/// From app/VERSION, which build.py copies into Info.plist.
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
let claudeData = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude")
// Claude's page needs a moment after its window shows before DevTools can reach it.
let pageLoadDelay: Duration = .seconds(3)
let contributingGuide = URL(string: "https://github.com/thomasdqr/claude-desktop-mods/blob/main/CONTRIBUTING.md")!

// MARK: - Palette

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let canvas = Color(light: NSColor(srgbRed: 0.980, green: 0.976, blue: 0.961, alpha: 1),
                              dark: NSColor(srgbRed: 0.098, green: 0.098, blue: 0.094, alpha: 1))
    static let card = Color(light: .white,
                            dark: NSColor(srgbRed: 0.165, green: 0.165, blue: 0.157, alpha: 1))
    static let hairline = Color(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.12))
    /// Secondary text, brighter than the system's on the dark canvas.
    static let muted = Color(light: NSColor(white: 0, alpha: 0.6), dark: NSColor(white: 1, alpha: 0.7))
    static let outline = Color(light: NSColor(white: 0, alpha: 0.18), dark: NSColor(white: 1, alpha: 0.25))
    static let accent = Color(light: NSColor(srgbRed: 0.180, green: 0.420, blue: 0.820, alpha: 1),
                              dark: NSColor(srgbRed: 0.420, green: 0.640, blue: 0.930, alpha: 1))
    static let accentWash = Color(light: NSColor(srgbRed: 0.910, green: 0.940, blue: 0.990, alpha: 1),
                                  dark: NSColor(srgbRed: 0.035, green: 0.125, blue: 0.260, alpha: 1))
    static let knob = Color(light: .white, dark: NSColor(srgbRed: 0.098, green: 0.098, blue: 0.094, alpha: 1))
}

// MARK: - Keyboard and window automation

enum Automation {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    static func askForPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func press(_ key: CGKeyCode, _ flags: CGEventFlags = [], to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.postToPid(pid)
        }
    }

    static func type(_ text: String, to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for var unit in text.utf16 {
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                event?.postToPid(pid)
            }
        }
    }

    static func windowTitles(of pid: pid_t) -> [String] {
        windows(of: pid).map { string($0, kAXTitleAttribute) }
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    /// Whether the window shows DevTools' own page. Claude opens other windows, some hidden.
    static func isDevTools(_ window: AXUIElement) -> Bool {
        webPage(in: window) { $0.scheme == "devtools" } != nil
    }

    /// Electron only shows its web pages to Accessibility while asked to.
    static func showWebPages(_ on: Bool, of pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString,
                                     on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// The first web page under `element` whose address matches.
    static func webPage(in element: AXUIElement, depth: Int = 0, where matches: (URL) -> Bool) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == "AXWebArea" {
            var url: CFTypeRef?
            AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &url)
            if let url = url as? URL, matches(url) { return element }
        }
        guard depth < 12 else { return nil }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] {
            if let page = webPage(in: child, depth: depth + 1, where: matches) { return page }
        }
        return nil
    }

    static func title(of window: AXUIElement) -> String {
        string(window, kAXTitleAttribute)
    }

    static func focusedRole(of pid: pid_t) -> String {
        var element: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &element)
        guard let element else { return "" }
        return string(element as! AXUIElement, kAXRoleAttribute)
    }

    /// Since macOS 14, an app can't take the front back from another on its own; Accessibility
    /// can. Off the main thread, so this app can answer the request when it's about itself.
    static func bringToFront(_ pid: pid_t) {
        DispatchQueue.global().async {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    static func isTyping(in pid: pid_t) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox"].contains(focusedRole(of: pid))
    }

    static func isFocused(_ window: AXUIElement, of pid: pid_t) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value)
        return value.map { CFEqual($0, window) } ?? false
    }

    /// Shrinks the window as far as it goes, into the bottom-right corner of the main screen and
    /// nearly all off it. DevTools saves its bounds when it closes, so it opens there next time.
    static func tuckAway(_ window: AXUIElement) {
        guard let screen = NSScreen.screens.first?.frame else { return }
        var size = CGSize(width: 1, height: 1)
        // Accessibility positions start at the top-left of the main screen.
        var origin = CGPoint(x: screen.maxX - 4, y: screen.height - 4)
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    static func close(_ window: AXUIElement) {
        var button: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button)
        if let button {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String ?? ""
    }
}

enum Key {
    static let i: CGKeyCode = 34
    static let p: CGKeyCode = 35
    static let enter: CGKeyCode = 36
}

/// Polls `condition` every `interval` until it holds or `timeout` passes.
func waitUntil(timeout: Duration, interval: Duration = .milliseconds(200), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return condition()
}

// MARK: - Mods

struct SettingOption: Hashable {
    let value: String
    let label: String
}

/// One entry of a manifest's "settings" list. "hidden" settings are edited elsewhere,
/// like color-tabs' projects, which its icon picker edits inside Claude.
struct SettingSpec: Identifiable {
    let key: String
    let type: String
    let label: String
    let detail: String
    let options: [SettingOption]
    let defaultValue: Any?
    let range: ClosedRange<Int>
    var id: String { key }

    init(_ json: [String: Any]) {
        key = json["key"] as? String ?? ""
        type = json["type"] as? String ?? "hidden"
        label = json["label"] as? String ?? key
        detail = json["description"] as? String ?? ""
        options = (json["options"] as? [[String: String]] ?? []).map {
            SettingOption(value: $0["value"] ?? "", label: $0["label"] ?? $0["value"] ?? "")
        }
        defaultValue = json["default"]
        range = (json["min"] as? Int ?? 0)...(json["max"] as? Int ?? 99)
    }
}

struct ModInfo: Identifiable {
    let id: String
    let name: String
    let version: String
    let description: String
    let author: String
    /// An SF Symbol and a hex color, from the manifest's "icon".
    let symbol: String
    let color: Color
    let settings: [SettingSpec]
    var visibleSettings: [SettingSpec] { settings.filter { $0.type != "hidden" } }

    init(_ json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? id
        version = json["version"] as? String ?? ""
        description = json["description"] as? String ?? ""
        author = json["author"] as? String ?? ""
        let icon = json["icon"] as? [String: String] ?? [:]
        symbol = icon["symbol"] ?? "puzzlepiece.extension.fill"
        color = Color(hex: icon["color"] ?? "#9AA3AE")
        settings = (json["settings"] as? [[String: Any]] ?? []).map(SettingSpec.init)
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case catalog = "Catalog"
    case settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .installed: "square.grid.2x2"
        case .catalog: "safari"
        case .settings: "gearshape"
        }
    }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    /// Every mod in the repository's mods/ folder: the catalog.
    @Published var mods: [ModInfo] = []
    /// The contents of settings.json: the installed mods, each with its switch and
    /// settings. install.py bundles them into the snippet, so changes apply when Claude restarts.
    @Published var modSettings: [String: Any] = [:]
    /// settings.json as Claude last loaded it, or empty while the mods are off.
    @Published private var appliedSettings: [String: Any] = [:]
    @Published var tab: Tab = .installed
    /// The installed mod whose settings are unfolded.
    @Published var openSettings: String?
    let claudeVersion = (NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID))
        .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    @Published var claudeRunning = false
    @Published var developerMode = false
    @Published var snippetInstalled = false
    /// Each mod's version in the snippet Claude has, from the bundle's "// Mods:" line.
    @Published var loadedVersions: [String: String] = [:]
    /// Mods with a higher version upstream, and that version.
    @Published var updates: [String: String] = [:]
    /// What each update changes: the subject of the commit that raised its version.
    @Published var updateNotes: [String: String] = [:]
    /// A higher version of this app, upstream or pulled but not built yet.
    @Published var appUpdate: String?
    /// Whether this app ran the mods in the Claude that's open: live settings need them running,
    /// from a snippet whose runtime takes them.
    @Published private var ranMods = false
    @Published private var snippetTakesLiveSettings = false
    @Published var checkingForUpdates = false
    @Published var lastChecked: Date?
    @Published var autoCheck = UserDefaults.standard.object(forKey: "autoCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheck") }
    }
    @Published var accessibilityAllowed = Automation.isAllowed
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var busy: String?
    // View state lives here rather than in SwiftUI's @State: on some Macs @State is a macro
    // whose plugin only ships with Xcode, and the launcher must build with the command line tools.
    /// The state the user asked for, waiting for them to confirm the Claude restart.
    @Published var pendingEnabled: Bool?
    @Published var confirmingUninstall = false
    @Published var skippedPermission = false
    @Published var message: String?
    @Published var autoApply = UserDefaults.standard.object(forKey: "autoApply") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoApply, forKey: "autoApply") }
    }

    var enabled: Bool { developerMode && snippetInstalled }
    private var claude: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first
    }

    init() {
        loadMods()
        refresh()
        appliedSettings = snippetInstalled ? modSettings : [:]
        // Opened while Claude runs, say after an update: it ran them at Claude's launch.
        ranMods = claudeRunning && snippetInstalled && autoApply
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if autoCheck { Task { await checkForUpdates() } }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.autoCheck == true { await self?.checkForUpdates() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == claudeBundleID else { return }
            Task { @MainActor in await self?.applyAfterLaunch() }
        }
    }

    func refresh() {
        claudeRunning = claude != nil
        if !claudeRunning { ranMods = false }
        accessibilityAllowed = Automation.isAllowed
        openAtLogin = SMAppService.mainApp.status == .enabled
        let developerSettings = readJSON(claudeData.appendingPathComponent("developer_settings.json"))
        developerMode = developerSettings?["allowDevTools"] as? Bool ?? false
        let snippet = installedSnippets().first { $0["name"] as? String == "cdm" }
        snippetInstalled = snippet != nil
        let bundle = snippet?["content"] as? String ?? ""
        snippetTakesLiveSettings = bundle.contains("__cdm.configure")
        let modsLine = bundle.split(separator: "\n").first { $0.hasPrefix("// Mods: ") } ?? ""
        loadedVersions = Dictionary(modsLine.dropFirst(9).split(separator: ", ").compactMap { item in
            let parts = item.split(separator: "@")
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { first, _ in first })
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func installedSnippets() -> [[String: Any]] {
        let preferences = readJSON(claudeData.appendingPathComponent("Preferences"))
        let devtools = (preferences?["electron"] as? [String: Any])?["devtools"] as? [String: Any]
        let snippets = (devtools?["preferences"] as? [String: Any])?["script-snippets"] as? String ?? "[]"
        return (try? JSONSerialization.jsonObject(with: Data(snippets.utf8))) as? [[String: Any]] ?? []
    }

    // MARK: Mods and their settings

    private var settingsURL: URL { URL(fileURLWithPath: repoPath).appendingPathComponent("settings.json") }

    func loadMods() {
        let folder = URL(fileURLWithPath: repoPath).appendingPathComponent("mods")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        mods = ids.sorted().compactMap { id in
            readJSON(folder.appendingPathComponent(id).appendingPathComponent("manifest.json")).map(ModInfo.init)
        }
        modSettings = readJSON(settingsURL) ?? ["mods": [String: Any]()]
    }

    private func entry(_ mod: ModInfo) -> [String: Any] {
        (modSettings["mods"] as? [String: Any])?[mod.id] as? [String: Any] ?? [:]
    }

    var installed: [ModInfo] { mods.filter(isInstalled) }

    func isInstalled(_ mod: ModInfo) -> Bool { (modSettings["mods"] as? [String: Any])?[mod.id] != nil }

    func isOn(_ mod: ModInfo) -> Bool { entry(mod)["enabled"] as? Bool ?? true }

    func install(_ mod: ModInfo) {
        update(mod) { $0["enabled"] = true }
        tab = .installed
    }

    func remove(_ mod: ModInfo) {
        var all = modSettings["mods"] as? [String: Any] ?? [:]
        all[mod.id] = nil
        modSettings["mods"] = all
        save()
    }

    func value(_ mod: ModInfo, _ spec: SettingSpec) -> Any? {
        (entry(mod)["settings"] as? [String: Any])?[spec.key] ?? spec.defaultValue
    }

    func setOn(_ mod: ModInfo, _ on: Bool) {
        update(mod) { $0["enabled"] = on }
    }

    func setValue(_ mod: ModInfo, _ spec: SettingSpec, _ value: Any) {
        update(mod) { entry in
            var settings = entry["settings"] as? [String: Any] ?? [:]
            settings[spec.key] = value
            entry["settings"] = settings
        }
    }

    /// The changed settings of mods running in Claude, which can restart with them there.
    private var liveChanges: [String: [String: Any]] {
        let now = running(modSettings), before = running(appliedSettings)
        var changes: [String: [String: Any]] = [:]
        for (id, new) in now {
            // A mod whose code in Claude is older waits for the restart, settings included.
            guard let old = before[id], loadedVersions[id] == mods.first(where: { $0.id == id })?.version else { continue }
            let changed = new.filter { !($0.value as AnyObject).isEqual(old[$0.key]) }
            if !changed.isEmpty { changes[id] = changed }
        }
        return changes
    }

    /// Whether every waiting change is a setting that applies without restarting Claude.
    var changesApplyLive: Bool {
        ranMods && snippetTakesLiveSettings && claudeRunning
            && liveChanges.values.reduce(0) { $0 + $1.count } == pendingChanges
    }

    /// Sends the changed settings to the mods running in Claude, which restart with them.
    func applyLiveSettings() async {
        let changes = liveChanges
        guard !changes.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: changes, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        let command = "window.__cdm?.configure(\(String(decoding: json, as: UTF8.self)))"
        let sent = await inDevTools("Applying settings…") { pid, devTools in
            // The command menu's Show Console puts the cursor in the console.
            Automation.press(Key.p, [.maskCommand, .maskShift], to: pid)
            guard await waitUntil(timeout: .milliseconds(1500), interval: .milliseconds(30), {
                Automation.isFocused(devTools, of: pid) && Automation.isTyping(in: pid)
            }) else { return false }
            Automation.type("Show Console", to: pid)
            try? await Task.sleep(for: .milliseconds(200))
            Automation.press(Key.enter, to: pid)
            // Types into Claude only while the cursor is in DevTools, never in a chat.
            guard await waitUntil(timeout: .milliseconds(1500), interval: .milliseconds(30), {
                Automation.isFocused(devTools, of: pid) && Automation.isTyping(in: pid)
            }) else { return false }
            Automation.type(command, to: pid)
            try? await Task.sleep(for: .milliseconds(150))
            Automation.press(Key.enter, to: pid)
            return true
        }
        // Claude came to the front for DevTools: give the window back to the user's next change.
        Automation.bringToFront(ProcessInfo.processInfo.processIdentifier)
        guard sent else { return }
        var applied = appliedSettings["mods"] as? [String: Any] ?? [:]
        let current = modSettings["mods"] as? [String: Any] ?? [:]
        for id in changes.keys { applied[id] = current[id] }
        appliedSettings["mods"] = applied
        message = "Applied in Claude."
    }

    private func update(_ mod: ModInfo, _ change: (inout [String: Any]) -> Void) {
        var all = modSettings["mods"] as? [String: Any] ?? [:]
        var modEntry = all[mod.id] as? [String: Any] ?? ["enabled": true, "settings": [String: Any]()]
        change(&modEntry)
        all[mod.id] = modEntry
        modSettings["mods"] = all
        save()
    }

    private func save() {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? JSONSerialization.data(withJSONObject: modSettings, options: options) {
            try? data.write(to: settingsURL)
        }
    }

    /// The installed mods that are on, with every setting resolved: what Claude runs.
    private func running(_ settings: [String: Any]) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for mod in mods {
            guard let entry = (settings["mods"] as? [String: Any])?[mod.id] as? [String: Any],
                  entry["enabled"] as? Bool ?? true else { continue }
            let values = entry["settings"] as? [String: Any] ?? [:]
            result[mod.id] = Dictionary(uniqueKeysWithValues: mod.settings.map {
                ($0.key, values[$0.key] ?? $0.defaultValue ?? NSNull())
            })
        }
        return result
    }

    /// How many mods and settings differ from what Claude runs: a mod turned on or off
    /// counts once, and so does each changed setting or new version of a mod that's on.
    var pendingChanges: Int {
        let now = running(modSettings), before = running(appliedSettings)
        return Set(now.keys).union(before.keys).reduce(0) { count, id in
            guard let new = now[id], let old = before[id] else { return count + 1 }
            let loaded = loadedVersions[id], version = mods.first { $0.id == id }?.version
            let newVersion = loaded != nil && loaded != version ? 1 : 0
            return count + newVersion + new.keys.filter { !(new[$0]! as AnyObject).isEqual(old[$0]) }.count
        }
    }

    // MARK: Updates

    /// Compares each mod's version with the one on the repository's upstream branch.
    /// Only looks: updating is always the user's click.
    func checkForUpdates() async {
        checkingForUpdates = true
        defer { checkingForUpdates = false }
        guard await git("fetch", "--quiet") != nil else {
            message = "Couldn't check for updates. Are you online?"
            return
        }
        var found: [String: String] = [:], notes: [String: String] = [:]
        for mod in mods {
            let manifest = "mods/\(mod.id)/manifest.json"
            guard let text = await git("show", "@{u}:\(manifest)"),
                  let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let version = json["version"] as? String,
                  version.compare(mod.version, options: .numeric) == .orderedDescending else { continue }
            found[mod.id] = version
            // Optional: a commit titled "color-tabs 1.2.0: longer light (#1)" gives "longer light";
            // any other title gives no note.
            let subject = await git("log", "-1", "--format=%s", "@{u}", "--", manifest) ?? ""
            let prefix = "\(mod.id) \(version): "
            if subject.hasPrefix(prefix) {
                notes[mod.id] = String(subject.dropFirst(prefix.count))
                    .replacingOccurrences(of: #"\s*\(#\d+\)$"#, with: "", options: .regularExpression)
            }
        }
        updates = found
        updateNotes = notes
        let pulled = try? String(contentsOfFile: (repoPath as NSString).appendingPathComponent("app/VERSION"))
        let upstream = await git("show", "@{u}:app/VERSION")
        appUpdate = [pulled, upstream].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.compare(appVersion, options: .numeric) == .orderedDescending }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
        lastChecked = Date()
    }

    var updateCount: Int { updates.count + (appUpdate == nil ? 0 : 1) }

    /// Pulls the repository: every mod's update and the catalog's new mods at once.
    func update() async {
        busy = "Updating…"
        message = nil
        let pulled = await git("pull", "--ff-only", "--quiet") != nil
        busy = nil
        guard pulled else {
            message = "Couldn't update: the folder has changes of its own. Run git pull in Terminal."
            return
        }
        loadMods()
        updates = [:]
        updateNotes = [:]
    }

    func updateAll() async {
        if !updates.isEmpty { await update() }
        if appUpdate != nil, message == nil { await updateApp() }
    }

    /// Pulls, then rebuilds this app with app/build.py and reopens it.
    func updateApp() async {
        busy = "Updating the app…"
        message = nil
        guard await git("pull", "--ff-only", "--quiet") != nil else {
            busy = nil
            message = "Couldn't update: the folder has changes of its own. Run git pull in Terminal."
            return
        }
        guard let python else {
            busy = nil
            message = "Python 3 wasn't found."
            return
        }
        // build.py won't replace a running app, so a shell waits for this one to quit first.
        // It reopens the app even if the build fails: the old version is still in place then.
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Claude Desktop Mods update.log").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; "$2" "$3" > "$4" 2>&1; open "$5""#, "sh",
            String(ProcessInfo.processInfo.processIdentifier), python,
            (repoPath as NSString).appendingPathComponent("app/build.py"), log, Bundle.main.bundlePath,
        ]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            busy = nil
            message = "Couldn't update the app: \(error.localizedDescription)"
        }
    }

    var hasModsOn: Bool { installed.contains(where: isOn) }

    /// Restarts Claude with the installed mods that are on, or without mods if none are.
    func applyChanges() async {
        await setEnabled(hasModsOn)
    }

    // MARK: Actions

    func setEnabled(_ on: Bool) async {
        busy = on ? "Turning on mods…" : "Turning off mods…"
        message = nil
        await quitClaude()
        // The scripts write Claude's settings while it's closed, then reopen it.
        let output = await runScript(on ? "install.py" : "uninstall.py")
        if busy?.hasPrefix("Turning") == true { busy = nil }
        loadMods()
        refresh()
        appliedSettings = on ? modSettings : [:]
        if busy == nil, message == nil { message = output }
    }

    /// Removes Claude Desktop Mods and nothing of Claude's own: uninstall.py takes the
    /// snippet out and gives Developer Mode back, then the login item and this app go.
    func uninstall() async {
        await setEnabled(false)
        try? await SMAppService.mainApp.unregister()
        try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        NSApp.terminate(nil)
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change Open at login: \(error.localizedDescription)"
        }
        refresh()
    }

    func allowAccessibility() {
        Automation.askForPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func openConfigFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: repoPath))
    }

    private func applyAfterLaunch() async {
        // install.py reopens Claude before it exits, so the snippet it just saved isn't
        // in the last refresh yet.
        refresh()
        guard autoApply, enabled, Automation.isAllowed else { return }
        guard let pid = claude?.processIdentifier else { return }
        busy = "Waiting for Claude to open…"
        _ = await waitUntil(timeout: .seconds(30)) { !Automation.windowTitles(of: pid).isEmpty }
        try? await Task.sleep(for: pageLoadDelay)
        busy = nil
        await applyMods()
    }

    private func applyMods() async {
        ranMods = await inDevTools("Running mods…") { pid, devTools in
            Automation.press(Key.p, .maskCommand, to: pid)
            // Types into Claude only while the cursor is in DevTools, never in a chat.
            guard await waitUntil(timeout: .milliseconds(1500), interval: .milliseconds(30), {
                Automation.isFocused(devTools, of: pid) && Automation.isTyping(in: pid)
            }) else { return false }
            Automation.type("!cdm", to: pid)
            try? await Task.sleep(for: .milliseconds(150))
            Automation.press(Key.enter, to: pid)
            return true
        }
        if ranMods { message = "Mods running." }
    }

    /// Opens Claude's DevTools tucked off-screen, runs `steps` in it, then closes it.
    private func inDevTools(_ status: String, _ steps: (pid_t, AXUIElement) async -> Bool) async -> Bool {
        guard Automation.isAllowed else {
            message = "Allow Claude Desktop Mods in Accessibility first."
            return false
        }
        guard let claude else {
            message = "Open Claude first."
            return false
        }
        let pid = claude.processIdentifier
        busy = status
        message = nil
        defer { busy = nil }

        claude.activate()
        _ = await waitUntil(timeout: .seconds(2), interval: .milliseconds(30)) {
            NSWorkspace.shared.frontmostApplication == claude
        }

        Automation.showWebPages(true, of: pid)
        defer { Automation.showWebPages(false, of: pid) }
        // ⌥⌘I would close a DevTools left open, by the user or by a run that failed.
        for window in Automation.windows(of: pid) where Automation.isDevTools(window) { Automation.close(window) }
        let known = Automation.windows(of: pid)
        // ⌥⌘I opens DevTools for the page that has the cursor. Claude's window holds two: its
        // own frame, where the cursor is in a Code session, and claude.ai, where mods run.
        if let page = known.lazy.compactMap({ Automation.webPage(in: $0) { $0.host == "claude.ai" } }).first {
            AXUIElementSetAttributeValue(page, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        Automation.press(Key.i, [.maskCommand, .maskAlternate], to: pid)
        var found: AXUIElement?
        _ = await waitUntil(timeout: .seconds(8), interval: .milliseconds(50)) {
            found = Automation.windows(of: pid).first { window in
                !known.contains { CFEqual($0, window) } && Automation.isDevTools(window)
            }
            return found != nil
        }
        guard let devTools = found else {
            message = "DevTools didn't open. Are mods turned on?"
            return false
        }
        Automation.tuckAway(devTools)

        let done = await steps(pid, devTools)
        // Lets DevTools hand the code to the page before its window goes.
        try? await Task.sleep(for: .milliseconds(300))
        Automation.close(devTools)
        if !done { message = "DevTools didn't respond. Try again." }
        return done
    }

    private func quitClaude() async {
        guard let claude else { return }
        claude.terminate()
        if !(await waitUntil(timeout: .seconds(20)) { claude.isTerminated }) {
            busy = "Quit Claude to continue…"
            _ = await waitUntil(timeout: .seconds(600)) { claude.isTerminated }
        }
    }

    private func git(_ arguments: String...) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: process.terminationStatus == 0
                    ? output.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    private var python: String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private func runScript(_ name: String) async -> String {
        guard let python else { return "Python 3 wasn't found." }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [(repoPath as NSString).appendingPathComponent(name)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let lastLine = output.split(separator: "\n").last.map(String.init) ?? ""
                continuation.resume(returning: process.terminationStatus == 0 ? "Done." : "Failed: \(lastLine)")
            }
            do { try process.run() } catch { continuation.resume(returning: "Failed: \(error.localizedDescription)") }
        }
    }
}

// MARK: - Views

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline))
    }
}

// macOS draws its own switch in the system accent color, so this one always draws the app's blue.
struct Switch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accent : Color.secondary.opacity(0.3))
                .frame(width: 38, height: 22)
            Circle()
                .fill(Color.knob)
                .frame(width: 16, height: 16)
                .padding(3)
        }
        .animation(.easeOut(duration: 0.15), value: isOn)
        .contentShape(Capsule())
        .onTapGesture { isOn.toggle() }
        .opacity(isEnabled ? 1 : 0.5)
    }
}

struct SwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            Switch(isOn: configuration.$isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

struct AppButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.knob : destructive ? Color.red : Color.primary)
            .background(prominent ? Color.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? Color.clear : Color.outline))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ModIcon: View {
    let mod: ModInfo

    var body: some View {
        Image(systemName: mod.symbol)
            .font(.system(size: 15))
            .foregroundStyle(mod.color)
            .frame(width: 34, height: 34)
            .background(mod.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// A mod's icon, name, version and description: the start of its row in every list.
struct ModTitle: View {
    let mod: ModInfo
    /// A newer version, shown after the current one.
    var update: String?
    var body: some View {
        HStack(spacing: 12) {
            ModIcon(mod: mod)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(mod.name).font(.system(size: 13.5, weight: .semibold))
                    Text(mod.version).font(.system(size: 12)).foregroundStyle(Color.muted)
                    if let update {
                        Text("→ \(update)").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accent)
                    }
                }
                Text(mod.description).font(.system(size: 12)).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One line of a page's list, padded like the page header and followed by a hairline.
struct ListRow<Content: View>: View {
    var vertical: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 20)
                .padding(.vertical, vertical)
            Divider().overlay(Color.hairline)
        }
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        ListRow {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(SwitchStyle())
        }
    }
}

/// An installed mod: its switch, and behind the sliders button its settings and Remove.
struct InstalledRow: View {
    @EnvironmentObject var model: Model
    let mod: ModInfo

    var body: some View {
        let isOpen = model.openSettings == mod.id
        VStack(spacing: 0) {
            ListRow {
                HStack(spacing: 12) {
                    ModTitle(mod: mod, update: model.updates[mod.id])
                    Spacer(minLength: 8)
                    if model.updates[mod.id] != nil {
                        Button("Update") { Task { await model.update() } }
                            .buttonStyle(AppButtonStyle())
                            .disabled(model.busy != nil)
                    }
                    if !mod.visibleSettings.isEmpty {
                        Button {
                            model.openSettings = isOpen ? nil : mod.id
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(isOpen ? Color.accent : Color.primary.opacity(0.75))
                                .frame(width: 26, height: 26)
                                .background(isOpen ? Color.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Settings")
                    }
                    Switch(isOn: Binding(get: { model.isOn(mod) }, set: { model.setOn(mod, $0) }))
                }
            }
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(mod.visibleSettings) { spec in
                        SettingRow(mod: mod, spec: spec)
                    }
                    HStack {
                        Text("By \(mod.author)").font(.system(size: 12)).foregroundStyle(Color.muted)
                        Spacer()
                        Button {
                            model.openSettings = nil
                            model.remove(mod)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(AppButtonStyle(destructive: true))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .padding(.leading, 46)
                .background(Color.primary.opacity(0.025))
                Divider().overlay(Color.hairline)
            }
        }
    }
}

struct SettingRow: View {
    @EnvironmentObject var model: Model
    let mod: ModInfo
    let spec: SettingSpec

    var body: some View {
        switch spec.type {
        case "toggle":
            ToggleRow(
                title: spec.label,
                detail: spec.detail,
                isOn: Binding(get: { model.value(mod, spec) as? Bool ?? false }, set: { model.setValue(mod, spec, $0) })
            )
        case "choice":
            row {
                Picker("", selection: Binding(
                    get: { model.value(mod, spec) as? String ?? "" },
                    set: { model.setValue(mod, spec, $0) }
                )) {
                    ForEach(spec.options, id: \.self) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        case "number":
            let number = (model.value(mod, spec) as? NSNumber)?.intValue ?? spec.range.lowerBound
            row {
                Stepper(value: Binding(get: { number }, set: { model.setValue(mod, spec, $0) }), in: spec.range) {
                    Text("\(number)").font(.system(size: 12.5)).monospacedDigit()
                }
                .fixedSize()
            }
        default:
            EmptyView()
        }
    }

    private func row<Control: View>(@ViewBuilder _ control: () -> Control) -> some View {
        ListRow {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.label).font(.system(size: 13, weight: .medium))
                    Text(spec.detail).font(.system(size: 12)).foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                control()
            }
        }
    }
}

struct StatusRow: View {
    let title: String
    let value: String
    let ok: Bool

    var body: some View {
        ListRow(vertical: 9) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Badge(text: value, color: ok ? .green : Color.muted)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        Group {
            if model.accessibilityAllowed || model.skippedPermission {
                HStack(spacing: 0) {
                    sidebar
                    Divider().overlay(Color.hairline)
                    VStack(alignment: .leading, spacing: 0) {
                        pageHeader
                        Divider().overlay(Color.hairline)
                        ScrollView { page }
                        banner
                    }
                    .frame(minWidth: 440, maxWidth: .infinity)
                }
                .frame(minHeight: 420, maxHeight: .infinity)
            } else {
                // Fixed size: with .contentSize the window fits it, then grows for the main screen.
                VStack(alignment: .leading, spacing: 16) {
                    header
                    permissionStep
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                // Clears the traffic lights of the hidden title bar.
                .padding(.top, 30)
                .frame(width: 430)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Color.canvas)
        .alert(
            "Turn off Claude Desktop Mods?",
            isPresented: Binding(get: { model.pendingEnabled == false }, set: { if !$0 { model.pendingEnabled = nil } })
        ) {
            Button("Restart Claude") {
                model.pendingEnabled = nil
                Task { await model.setEnabled(false) }
            }
            Button("Cancel", role: .cancel) { model.pendingEnabled = nil }
        } message: {
            Text("Claude quits and reopens without mods. Your installed mods and their settings are kept.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text("Claude Desktop Mods")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            // Same height and top as the page header, so both titles sit on one line.
            .frame(height: 30)
            .padding(.horizontal, 4)
            .padding(.bottom, 24)
            ForEach(Tab.allCases) { tab in
                Button {
                    model.tab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbol).frame(width: 16)
                        Text(tab.rawValue)
                        Spacer()
                        if tab == .installed, model.updateCount > 0 {
                            Badge(text: model.updateCount == 1 ? "1 update" : "\(model.updateCount) updates",
                                  color: .accent)
                        } else if tab == .installed, !model.installed.isEmpty {
                            Text("\(model.installed.count)").foregroundStyle(Color.muted)
                        }
                    }
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(model.tab == tab ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.tab == tab ? Color.primary : Color.muted)
            }
            Spacer()
            status
        }
        .padding(.horizontal, 10)
        .padding(.top, 30)
        .padding(.bottom, 14)
        .frame(width: 230, alignment: .leading)
    }

    private var status: some View {
        let (symbol, color, text): (String, Color, String) =
            !model.claudeRunning ? ("circle", .gray, "Claude isn't open")
            : model.enabled ? ("checkmark.circle", .green, "Mods are running")
            : ("exclamationmark.circle", .orange, "Mods are off")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(model.claudeVersion.map { "Claude \($0)" } ?? "Claude")
            }
            Text(text).foregroundStyle(Color.muted)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
    }

    // MARK: Pages

    private var pageHeader: some View {
        HStack {
            Text(model.tab.rawValue).font(.system(size: 15, weight: .semibold))
            Spacer()
            if model.tab == .installed, !model.installed.isEmpty {
                Text(checkedText).font(.system(size: 12)).foregroundStyle(Color.muted)
                Button {
                    Task { await model.checkForUpdates() }
                } label: {
                    Label("Check for updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(AppButtonStyle())
                .disabled(model.checkingForUpdates || model.busy != nil)
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private var checkedText: String {
        if model.checkingForUpdates { return "Checking…" }
        guard let lastChecked = model.lastChecked else { return "" }
        let ago = Date().timeIntervalSince(lastChecked) < 60 ? "just now"
            : RelativeDateTimeFormatter().localizedString(for: lastChecked, relativeTo: Date())
        return "Checked \(ago)"
    }

    private var versionDetail: String {
        if model.appUpdate != nil { return "A new version is out. The app restarts to update." }
        if model.checkingForUpdates { return "Checking…" }
        return model.lastChecked == nil ? "Not checked yet" : "Up to date. \(checkedText)."
    }

    @ViewBuilder private var page: some View {
        switch model.tab {
        case .installed: installedPage
        case .catalog: catalogPage
        case .settings: settingsPage
        }
    }

    @ViewBuilder private var installedPage: some View {
        if model.installed.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 28)).foregroundStyle(Color.muted)
                Text("No mods yet").font(.system(size: 14, weight: .semibold))
                Text("Add mods to Claude Desktop from the catalog.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.muted)
                Button("Browse catalog") { model.tab = .catalog }
                    .buttonStyle(AppButtonStyle(prominent: true))
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
        } else {
            VStack(spacing: 0) {
                if model.updateCount > 0 { updatesBanner }
                ForEach(model.installed) { InstalledRow(mod: $0) }
            }
        }
    }

    private var updatesBanner: some View {
        let updated = model.mods.filter { model.updates[$0.id] != nil }
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 15)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.updateCount == 1 ? "1 update available" : "\(model.updateCount) updates available")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(updated) { mod in
                        let note = model.updateNotes[mod.id].map { ": \($0)" } ?? ""
                        Text("\(mod.name) \(model.updates[mod.id] ?? "")\(note)")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let appUpdate = model.appUpdate {
                        Text("Claude Desktop Mods \(appUpdate): the app restarts to update").font(.system(size: 12))
                    }
                }
                Spacer(minLength: 8)
                Button("Update all") { Task { await model.updateAll() } }
                    .buttonStyle(AppButtonStyle(prominent: true))
                    .disabled(model.busy != nil)
            }
            .foregroundStyle(Color.accent)
            .padding(12)
            .background(Color.accentWash, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            Divider().overlay(Color.hairline)
        }
    }

    private var catalogPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.mods) { mod in
                ListRow {
                    HStack(spacing: 10) {
                        ModTitle(mod: mod)
                        Spacer(minLength: 8)
                        if model.isInstalled(mod) {
                            Badge(text: "Installed", color: .green)
                        } else {
                            Button("Install") { model.install(mod) }
                                .buttonStyle(AppButtonStyle())
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Want to add your own mod?").foregroundStyle(Color.muted)
                Link("Read the guide ↗", destination: contributingGuide).foregroundStyle(Color.accent)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            ListRow {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Version \(appVersion)").font(.system(size: 13, weight: .medium))
                        Text(versionDetail).font(.system(size: 12)).foregroundStyle(Color.muted)
                    }
                    Spacer(minLength: 8)
                    if let appUpdate = model.appUpdate {
                        Button("Update to \(appUpdate)") { Task { await model.updateApp() } }
                            .buttonStyle(AppButtonStyle(prominent: true))
                            .disabled(model.busy != nil)
                    } else {
                        Button {
                            Task { await model.checkForUpdates() }
                        } label: {
                            Label("Check for updates", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(AppButtonStyle())
                        .disabled(model.checkingForUpdates || model.busy != nil)
                    }
                }
            }
            ToggleRow(
                title: "Run mods when Claude opens",
                detail: "Runs them a few seconds after Claude starts.",
                isOn: $model.autoApply
            )
            ToggleRow(
                title: "Check for updates automatically",
                detail: "At launch, then every 6 hours. Updating is always your click.",
                isOn: $model.autoCheck
            )
            ToggleRow(
                title: "Open at login",
                detail: "Stays in the menu bar, ready for each launch.",
                isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) })
            )
            if !model.accessibilityAllowed {
                ListRow {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(Color.accent)
                        Text("Allow Accessibility so it can type the shortcuts.")
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Allow…") { model.allowAccessibility() }
                            .buttonStyle(AppButtonStyle(prominent: true))
                    }
                }
            }
            StatusRow(title: "Developer Mode", value: model.developerMode ? "On" : "Off", ok: model.developerMode)
            StatusRow(title: "Mods in Claude",
                      value: model.snippetInstalled ? "Loaded" : model.hasModsOn ? "Loaded after restart" : "None turned on",
                      ok: model.snippetInstalled)
            StatusRow(title: "Accessibility", value: model.accessibilityAllowed ? "Allowed" : "Not allowed",
                      ok: model.accessibilityAllowed)
            HStack {
                Button {
                    model.openConfigFolder()
                } label: {
                    Label("Open folder", systemImage: "folder")
                }
                .buttonStyle(AppButtonStyle())
                Spacer()
                if model.enabled {
                    Button("Turn off mods") { model.pendingEnabled = false }
                        .buttonStyle(AppButtonStyle())
                        .disabled(model.busy != nil)
                }
                Button("Uninstall…") { model.confirmingUninstall = true }
                    .buttonStyle(AppButtonStyle(destructive: true))
                    .disabled(model.busy != nil)
            }
            .padding(20)
        }
        .alert("Uninstall Claude Desktop Mods?", isPresented: $model.confirmingUninstall) {
            Button("Uninstall", role: .destructive) { Task { await model.uninstall() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Claude restarts without mods, Developer Mode goes back to how it was, and this app moves to the Trash. Claude, your conversations and its settings stay as they are. The repository folder stays too.")
        }
    }

    /// The one place that applies changes: shown only while some are waiting for a restart.
    @ViewBuilder private var banner: some View {
        if model.busy != nil || model.pendingChanges > 0 || model.message != nil {
            HStack(spacing: 10) {
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy)
                } else if model.pendingChanges > 0, model.changesApplyLive {
                    Image(systemName: "checkmark.circle")
                    Text(model.pendingChanges == 1 ? "1 change, no restart needed"
                         : "\(model.pendingChanges) changes, no restart needed")
                    Spacer(minLength: 8)
                    Button("Apply") { Task { await model.applyLiveSettings() } }
                        .buttonStyle(AppButtonStyle())
                } else if model.pendingChanges > 0 {
                    Image(systemName: "arrow.clockwise")
                    Text(model.pendingChanges == 1 ? "1 change applies at next launch"
                         : "\(model.pendingChanges) changes apply at next launch")
                    Spacer(minLength: 8)
                    Button("Restart Claude") { Task { await model.applyChanges() } }
                        .buttonStyle(AppButtonStyle())
                } else if let message = model.message {
                    Text(message)
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Color.accent)
            .frame(minHeight: 28)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentWash, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(Color.accent)
                        Text("One permission first").font(.system(size: 15, weight: .semibold))
                    }
                    Text("Claude Desktop Mods runs your mods by typing DevTools shortcuts in Claude. macOS only allows that with Accessibility.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        permissionStepLine(1, "Click Open Settings.")
                        permissionStepLine(2, "Turn on Claude Desktop Mods in the list.")
                        permissionStepLine(3, "Already on but not detected? Select it, remove it with −, then add it back with +.")
                    }
                    HStack(spacing: 8) {
                        Button("Open Settings") { model.allowAccessibility() }
                            .buttonStyle(AppButtonStyle(prominent: true))
                        Button("Relaunch") { model.relaunch() }
                            .buttonStyle(AppButtonStyle())
                            .help("Some Macs only see the permission after a relaunch")
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text("Waiting…").font(.system(size: 11.5)).foregroundStyle(Color.muted)
                    }
                }
                .padding(16)
            }
            Button("Skip for now") { model.skippedPermission = true }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.muted)
        }
    }

    private func permissionStepLine(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Color.accent.opacity(0.18), in: Circle())
                .foregroundStyle(Color.accent)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // The permission step's header; the main screen has the sidebar instead.
    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Desktop Mods").font(.system(size: 21, weight: .regular, design: .serif)).fixedSize()
                Text("Mods for Claude Desktop")
                    .font(.system(size: 12)).foregroundStyle(Color.muted)
            }
            Spacer()
            Button {
                model.openConfigFolder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(AppButtonStyle())
            .help("Open the Claude Desktop Mods folder")
        }
    }

}

struct MenuContent: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.updateCount > 0 {
            Button(model.updateCount == 1 ? "Install 1 update" : "Install \(model.updateCount) updates") {
                Task { await model.updateAll() }
            }
            Divider()
        }
        Button("Check for updates") { Task { await model.checkForUpdates() } }
        Button("Open Claude Desktop Mods…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Claude Desktop Mods") { NSApp.terminate(nil) }
    }
}

@main
struct ClaudeDesktopModsApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        Window("Claude Desktop Mods", id: "main") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 680, height: 420)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Claude Desktop Mods", systemImage: "puzzlepiece.extension.fill") {
            MenuContent().environmentObject(model)
        }
    }
}
