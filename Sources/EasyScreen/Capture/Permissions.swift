import AppKit

enum Permissions {
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt the first time; afterwards macOS only lets the
    /// user flip the switch in System Settings.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
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

    /// Shown when a capture fails because permission is missing.
    @MainActor
    static func presentScreenRecordingAlert() {
        requestScreenRecording()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "EasyScreen needs Screen Recording permission"
        alert.informativeText = """
        To take screenshots, enable EasyScreen in System Settings → Privacy & Security → \
        Screen & System Audio Recording, then relaunch EasyScreen.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch EasyScreen")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openScreenRecordingSettings()
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
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
