import AppKit

/// Screen Recording permission handling.
///
/// macOS stores this permission against the app's code signature. If an entry
/// for an older or differently-signed build exists, System Settings shows
/// EasyScreen as switched on while this build is still refused — so besides
/// the normal prompt we offer a one-click reset of our own entry.
enum Permissions {
    private static let requestedVersionKey = "screenRecordingRequestedForVersion"
    private static let requestOnLaunchKey = "screenRecordingRequestOnLaunch"

    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Shows the macOS prompt (macOS only displays it while this build has no
    /// decision recorded) and remembers that this version has asked.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        UserDefaults.standard.set(currentVersion, forKey: requestedVersionKey)
        return CGRequestScreenCaptureAccess()
    }

    /// Called when a capture can't run for lack of permission. Uses the system
    /// prompt the first time for each version and EasyScreen's own guidance
    /// afterwards — never both at once.
    @MainActor
    static func handleMissingScreenRecording() {
        if UserDefaults.standard.string(forKey: requestedVersionKey) != currentVersion {
            requestScreenRecording()
        } else {
            presentScreenRecordingAlert()
        }
    }

    /// Call at launch: after a reset, ask macOS again on the fresh start.
    @MainActor
    static func requestAfterResetIfNeeded() {
        guard UserDefaults.standard.bool(forKey: requestOnLaunchKey) else { return }
        UserDefaults.standard.removeObject(forKey: requestOnLaunchKey)
        if !hasScreenRecording {
            requestScreenRecording()
        }
    }

    static func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Step-by-step help, including the "it's already on" case.
    @MainActor
    static func presentScreenRecordingAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow EasyScreen to record your screen"
        alert.informativeText = """
        1. Open System Settings → Privacy & Security → Screen & System Audio Recording.
        2. Turn on EasyScreen.
        3. Choose “Quit & Reopen” when macOS offers it (or click Relaunch here).

        Already switched on? That entry belongs to a different build of EasyScreen. \
        Click “Reset Permission” — EasyScreen removes its old entry and relaunches, \
        and macOS asks you again.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Reset Permission")
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openScreenRecordingSettings()
        case .alertSecondButtonReturn:
            resetScreenRecordingAndRelaunch()
        case .alertThirdButtonReturn:
            relaunch()
        default:
            break
        }
    }

    /// Removes EasyScreen's own (possibly stale) Screen Recording entry, then
    /// relaunches so macOS prompts for this build.
    @MainActor
    static func resetScreenRecordingAndRelaunch() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", bundleID]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {}

        guard task.terminationStatus == 0 else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't reset the permission automatically"
            alert.informativeText = """
            Remove EasyScreen from the Screen & System Audio Recording list with the “–” button, \
            or run this in Terminal, then reopen EasyScreen:

            tccutil reset ScreenCapture \(bundleID)
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
            return
        }
        UserDefaults.standard.set(true, forKey: requestOnLaunchKey)
        relaunch()
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
