import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var hotkeys: HotkeyManager
    @StateObject private var system = SystemStatus()

    var body: some View {
        Form {
            afterCaptureSection
            shortcutsSection
            screenshotModeSection
            generalSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
        .onAppear { system.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in system.refresh() }
    }

    // MARK: After capture

    private var afterCaptureSection: some View {
        Section {
            Toggle(isOn: $prefs.openEditor) {
                Label("Open in editor", systemImage: "pencil.and.outline")
            }
            Toggle(isOn: $prefs.copyToClipboard) {
                Label("Copy to clipboard", systemImage: "doc.on.clipboard")
            }
            Toggle(isOn: $prefs.saveToFolder) {
                Label("Save to folder", systemImage: "folder")
            }
            if prefs.saveToFolder {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(displayPath(prefs.saveFolderPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(prefs.saveFolderPath)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                    Button {
                        let url = prefs.saveFolderURL
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Open folder in Finder")
                }
            }
            Picker("File format", selection: $prefs.imageFormat) {
                ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("File name prefix", text: $prefs.filenamePrefix, prompt: Text("Screenshot"))
        } header: {
            Text("After capture")
        } footer: {
            if prefs.hasNoActions {
                Label("No action is enabled, so captures won't go anywhere.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Text("Every checked action runs at the same time on each capture.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        Section {
            ForEach(HotkeyAction.allCases) { action in
                LabeledContent {
                    ShortcutRecorder(combo: prefs.hotkey(for: action)) { prefs.setHotkey($0, for: action) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                        if hotkeys.failedActions.contains(action) {
                            Text("In use by another app — pick a different shortcut")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { prefs.resetHotkeys() }
            }
        } header: {
            Text("Keyboard shortcuts")
        } footer: {
            Text("Click a shortcut, then press the new key combination. Esc cancels, ⌫ clears.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    // MARK: Screenshot mode

    private var screenshotModeSection: some View {
        Section("Screenshot mode") {
            Toggle("Show magnifier while selecting", isOn: $prefs.showMagnifier)
            Toggle("Play capture sound", isOn: $prefs.playSound)
            Toggle("Show confirmation bubble", isOn: $prefs.showConfirmation)
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch EasyScreen at login", isOn: Binding(
                get: { system.launchAtLogin },
                set: { system.setLaunchAtLogin($0) }
            ))
            if system.loginItemNeedsApproval {
                HStack {
                    Text("Approve EasyScreen in Login Items to finish enabling this.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }

            LabeledContent("Screen Recording") {
                if system.hasScreenRecording {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Label("Not allowed", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Button("Grant…") {
                            Permissions.requestScreenRecording()
                            Permissions.openScreenRecordingSettings()
                        }
                        Button("Relaunch") { Permissions.relaunch() }
                            .help("macOS applies the permission after EasyScreen restarts")
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 36, height: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("EasyScreen \(AppInfo.version)").font(.headline)
                    Text("Free and open source · MIT License").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Link("GitHub", destination: AppInfo.repositoryURL)
                Button("Quit EasyScreen") { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Helpers

    private func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where EasyScreen saves screenshots"
        panel.directoryURL = prefs.saveFolderURL
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            prefs.saveFolderPath = url.path
        }
    }
}

/// Live system state shown in Settings (login item, permission).
final class SystemStatus: ObservableObject {
    @Published var launchAtLogin = false
    @Published var loginItemNeedsApproval = false
    @Published var hasScreenRecording = false

    func refresh() {
        let status = SMAppService.mainApp.status
        let enabled = status == .enabled
        let needsApproval = status == .requiresApproval
        let screen = Permissions.hasScreenRecording
        if enabled != launchAtLogin { launchAtLogin = enabled }
        if needsApproval != loginItemNeedsApproval { loginItemNeedsApproval = needsApproval }
        if screen != hasScreenRecording { hasScreenRecording = screen }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = enabled ? "Couldn't enable launch at login" : "Couldn't disable launch at login"
            alert.informativeText = """
            \(error.localizedDescription)

            Make sure EasyScreen is in your Applications folder, then try again.
            """
            alert.runModal()
        }
        refresh()
    }
}

/// Hosts `SettingsView` in a normal window.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    var onVisibilityChanged: (() -> Void)?

    private init() {
        let hosting = NSHostingController(rootView: SettingsView(prefs: .shared, hotkeys: .shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "EasyScreen Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 520, height: min(780, (NSScreen.main?.visibleFrame.height ?? 900) - 80)))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        onVisibilityChanged?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { self.onVisibilityChanged?() }
    }
}
