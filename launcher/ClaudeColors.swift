// Claude Colors launcher: turns the mod on or off, restarts Claude, and applies the
// colors each time Claude opens by typing the DevTools shortcuts (⌥⌘I, ⌘P,
// !claude-colors, Enter) in a DevTools window tucked off-screen, then closing it.
// Typing into Claude and moving its windows needs the Accessibility permission.
// Built into ~/Applications/Claude Colors.app by launcher/build.py.
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

let claudeBundleID = "com.anthropic.claudefordesktop"
let repoPath = Bundle.main.object(forInfoDictionaryKey: "ClaudeColorsRepo") as? String ?? ""
let claudeData = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude")
// Claude's page needs a moment after its window shows before DevTools can reach it.
let pageLoadDelay: Duration = .seconds(3)

// MARK: - Claude's palette

extension Color {
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)

    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let canvas = Color(light: NSColor(srgbRed: 0.980, green: 0.976, blue: 0.961, alpha: 1),
                              dark: NSColor(srgbRed: 0.149, green: 0.149, blue: 0.141, alpha: 1))
    static let card = Color(light: .white,
                            dark: NSColor(srgbRed: 0.188, green: 0.188, blue: 0.180, alpha: 1))
    static let hairline = Color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
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

    /// A window of `pid` that isn't one of `known`.
    static func newWindow(of pid: pid_t, besides known: [AXUIElement]) -> AXUIElement? {
        windows(of: pid).first { window in !known.contains { CFEqual($0, window) } }
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

    /// Shrinks the window into the bottom-right corner of the main screen, nearly all of it
    /// off-screen. DevTools saves its bounds when it closes, so it opens there next time.
    static func tuckAway(_ window: AXUIElement) {
        guard let screen = NSScreen.screens.first?.frame else { return }
        var size = CGSize(width: 480, height: 320)
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

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var claudeRunning = false
    @Published var developerMode = false
    @Published var snippetInstalled = false
    @Published var accessibilityAllowed = Automation.isAllowed
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var busy: String?
    // View state lives here rather than in SwiftUI's @State: on some Macs @State is a macro
    // whose plugin only ships with Xcode, and the launcher must build with the command line tools.
    /// The state the user asked for, waiting for them to confirm the Claude restart.
    @Published var pendingEnabled: Bool?
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
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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
        accessibilityAllowed = Automation.isAllowed
        openAtLogin = SMAppService.mainApp.status == .enabled
        let developerSettings = readJSON(claudeData.appendingPathComponent("developer_settings.json"))
        developerMode = developerSettings?["allowDevTools"] as? Bool ?? false
        snippetInstalled = installedSnippetNames().contains("claude-colors")
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func installedSnippetNames() -> [String] {
        let preferences = readJSON(claudeData.appendingPathComponent("Preferences"))
        let devtools = (preferences?["electron"] as? [String: Any])?["devtools"] as? [String: Any]
        let snippets = (devtools?["preferences"] as? [String: Any])?["script-snippets"] as? String ?? "[]"
        let list = (try? JSONSerialization.jsonObject(with: Data(snippets.utf8))) as? [[String: Any]] ?? []
        return list.compactMap { $0["name"] as? String }
    }

    // MARK: Actions

    func setEnabled(_ on: Bool) async {
        busy = on ? "Turning on Claude Colors…" : "Turning off Claude Colors…"
        message = nil
        await quitClaude()
        // The scripts write Claude's settings while it's closed, then reopen it.
        let output = await runScript(on ? "setup.py" : "uninstall.py")
        busy = nil
        refresh()
        message = output
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
        guard autoApply, enabled, Automation.isAllowed else { return }
        guard let pid = claude?.processIdentifier else { return }
        busy = "Waiting for Claude to open…"
        _ = await waitUntil(timeout: .seconds(30)) { !Automation.windowTitles(of: pid).isEmpty }
        try? await Task.sleep(for: pageLoadDelay)
        busy = nil
        await applyColors()
    }

    private func applyColors() async {
        guard Automation.isAllowed else {
            message = "Allow Claude Colors in Accessibility first."
            return
        }
        guard let claude else {
            message = "Open Claude first."
            return
        }
        let pid = claude.processIdentifier
        busy = "Applying colors…"
        message = nil
        defer { busy = nil }

        claude.activate()
        _ = await waitUntil(timeout: .seconds(2), interval: .milliseconds(30)) {
            NSWorkspace.shared.frontmostApplication == claude
        }

        let known = Automation.windows(of: pid)
        Automation.press(Key.i, [.maskCommand, .maskAlternate], to: pid)
        var found: AXUIElement?
        _ = await waitUntil(timeout: .seconds(6), interval: .milliseconds(30)) {
            found = Automation.newWindow(of: pid, besides: known)
            return found != nil
        }
        guard let devTools = found else {
            message = "DevTools didn't open. Is Claude Colors turned on?"
            return
        }
        Automation.tuckAway(devTools)

        // DevTools titles its window with the page's address once it has loaded,
        // which is also when ⌘P starts opening Quick Open.
        _ = await waitUntil(timeout: .seconds(6), interval: .milliseconds(30)) {
            Automation.title(of: devTools).contains("claude.ai")
        }
        Automation.press(Key.p, .maskCommand, to: pid)
        _ = await waitUntil(timeout: .milliseconds(1500), interval: .milliseconds(30)) {
            ["AXTextField", "AXTextArea", "AXComboBox"].contains(Automation.focusedRole(of: pid))
        }
        Automation.type("!claude-colors", to: pid)
        try? await Task.sleep(for: .milliseconds(150))
        Automation.press(Key.enter, to: pid)
        // Lets DevTools hand the snippet to the page before its window goes.
        try? await Task.sleep(for: .milliseconds(300))
        Automation.close(devTools)
        message = "Colors applied."
    }

    private func quitClaude() async {
        guard let claude else { return }
        claude.terminate()
        if !(await waitUntil(timeout: .seconds(20)) { claude.isTerminated }) {
            busy = "Quit Claude to continue…"
            _ = await waitUntil(timeout: .seconds(600)) { claude.isTerminated }
        }
    }

    private func runScript(_ name: String) async -> String {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let python = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return "Python 3 wasn't found."
        }
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

// macOS draws its own switch in the system accent color, so this one draws Claude's clay.
struct ClayToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Color.clay : Color.secondary.opacity(0.25))
                    .frame(width: 34, height: 20)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .opacity(isEnabled ? 1 : 0.5)
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(ClayToggleStyle())
        .disabled(disabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct StatusRow: View {
    let title: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer()
            Circle().fill(ok ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(value).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct ClayButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color.clay : Color.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? Color.clear : Color.hairline))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.accessibilityAllowed || model.skippedPermission {
                controls
            } else {
                permissionStep
            }
            footer
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        // Clears the traffic lights of the hidden title bar.
        .padding(.top, 30)
        .frame(width: 400)
        .background(Color.canvas)
        .alert(
            model.pendingEnabled == true ? "Turn on Claude Colors?" : "Turn off Claude Colors?",
            isPresented: Binding(get: { model.pendingEnabled != nil }, set: { if !$0 { model.pendingEnabled = nil } })
        ) {
            Button("Restart Claude") {
                guard let on = model.pendingEnabled else { return }
                model.pendingEnabled = nil
                Task { await model.setEnabled(on) }
            }
            Button("Cancel", role: .cancel) { model.pendingEnabled = nil }
        } message: {
            Text("Claude quits and reopens to apply the change.")
        }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(Color.clay)
                        Text("One permission first").font(.system(size: 15, weight: .semibold))
                    }
                    Text("Claude Colors applies your colors by typing DevTools shortcuts in Claude. macOS only allows that with Accessibility.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        permissionStepLine(1, "Click Open Settings.")
                        permissionStepLine(2, "Turn on Claude Colors in the list.")
                        permissionStepLine(3, "Already on but not detected? Select it, remove it with −, then add it back with +.")
                    }
                    HStack(spacing: 8) {
                        Button("Open Settings") { model.allowAccessibility() }
                            .buttonStyle(ClayButtonStyle(prominent: true))
                        Button("Relaunch") { model.relaunch() }
                            .buttonStyle(ClayButtonStyle())
                            .help("Some Macs only see the permission after a relaunch")
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text("Waiting…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            Button("Skip for now") { model.skippedPermission = true }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private func permissionStepLine(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Color.clay.opacity(0.18), in: Circle())
                .foregroundStyle(Color.clay)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                ToggleRow(
                    title: "Claude Colors",
                    detail: model.enabled
                        ? "On. Developer Mode and the snippet are installed."
                        : "Off. Turning it on restarts Claude once.",
                    isOn: Binding(get: { model.enabled }, set: { model.pendingEnabled = $0 }),
                    disabled: model.busy != nil
                )
            }
            Card {
                ToggleRow(
                    title: "Apply when Claude opens",
                    detail: "Types the DevTools shortcuts for you a few seconds after Claude starts.",
                    isOn: $model.autoApply
                )
                Divider().overlay(Color.hairline)
                ToggleRow(
                    title: "Open at login",
                    detail: "Keeps Claude Colors in the menu bar, ready for each Claude launch.",
                    isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) })
                )
                if !model.accessibilityAllowed {
                    Divider().overlay(Color.hairline)
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(Color.clay)
                        Text("Allow Accessibility so it can type the shortcuts.")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Allow…") { model.allowAccessibility() }
                            .buttonStyle(ClayButtonStyle(prominent: true))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            Card {
                StatusRow(title: "Claude", value: model.claudeRunning ? "Running" : "Not running", ok: model.claudeRunning)
                StatusRow(title: "Developer Mode", value: model.developerMode ? "On" : "Off", ok: model.developerMode)
                StatusRow(title: "Snippet", value: model.snippetInstalled ? "Installed" : "Missing", ok: model.snippetInstalled)
                StatusRow(title: "Accessibility", value: model.accessibilityAllowed ? "Allowed" : "Not allowed",
                          ok: model.accessibilityAllowed)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Colors").font(.system(size: 22, weight: .regular, design: .serif))
                Text("Colored blocks for Claude's sidebar")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.openConfigFolder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(ClayButtonStyle())
            .help("Open the Claude Colors folder")
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy)
            } else if let message = model.message {
                Text(message)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .frame(height: 16)
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Claude Colors…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Claude Colors") { NSApp.terminate(nil) }
    }
}

@main
struct ClaudeColorsApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        Window("Claude Colors", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Claude Colors", systemImage: "paintpalette.fill") {
            MenuContent().environmentObject(model)
        }
    }
}
