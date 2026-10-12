import AppKit

/// Runs a capture from start to finish: snapshot → selection → actions.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: SelectionOverlayController?
    private var isCapturing = false

    /// Interactive region capture (the default ⌘⇧1 action).
    func captureRegion(delay: TimeInterval = 0) {
        if let overlay, overlay.isActive {
            // Pressing the shortcut again while selecting cancels.
            overlay.cancel()
            return
        }
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            do {
                let windows = OnScreenWindow.current()
                let snapshots = try await ScreenCapturer.snapshotAllDisplays()
                let overlay = SelectionOverlayController()
                self.overlay = overlay
                overlay.begin(snapshots: snapshots, windows: windows) { [weak self, weak overlay] result in
                    guard let self else { return }
                    let previousApp = overlay?.previousApp
                    self.overlay = nil
                    self.isCapturing = false
                    if let result {
                        let screen = snapshots.first { NSMouseInRect(NSEvent.mouseLocation, $0.screen.frame, false) }?.screen
                        self.process(result, screen: screen, previousApp: previousApp)
                    } else {
                        Self.restoreFocus(to: previousApp)
                    }
                }
            } catch {
                isCapturing = false
                handle(error)
            }
        }
    }

    /// Captures the whole display under the mouse pointer.
    func captureFullScreen(delay: TimeInterval = 0) {
        guard !isCapturing, overlay == nil else { return }
        isCapturing = true
        let previousApp = NSWorkspace.shared.frontmostApplication

        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            defer { isCapturing = false }
            do {
                let snapshots = try await ScreenCapturer.snapshotAllDisplays()
                let mouse = NSEvent.mouseLocation
                guard let snapshot = snapshots.first(where: { NSMouseInRect(mouse, $0.screen.frame, false) })
                    ?? snapshots.first
                else { return }
                flash(on: snapshot.screen)
                let capture = CapturedImage(image: snapshot.image, scale: snapshot.scale, date: Date())
                process(capture, screen: snapshot.screen, previousApp: previousApp)
            } catch {
                handle(error)
            }
        }
    }

    /// Runs every enabled after-capture action, independently of each other.
    func process(_ capture: CapturedImage, screen: NSScreen?, previousApp: NSRunningApplication?) {
        let prefs = Preferences.shared
        if prefs.playSound { CaptureSound.play() }

        var confirmations: [String] = []
        var savedURL: URL?

        if prefs.copyToClipboard {
            ImageOutput.copyToClipboard(capture.image, scale: capture.scale)
            confirmations.append("Copied to clipboard")
        }

        if prefs.saveToFolder {
            do {
                savedURL = try ImageOutput.save(capture.image, scale: capture.scale, to: prefs.saveFolderURL,
                                                prefix: prefs.filenamePrefix, date: capture.date,
                                                format: prefs.imageFormat)
                confirmations.append("Saved to \(prefs.saveFolderURL.lastPathComponent)")
            } catch {
                showSaveError(error, folder: prefs.saveFolderURL)
            }
        }

        if prefs.openEditor {
            EditorManager.shared.open(capture, savedURL: savedURL, on: screen)
        } else {
            Self.restoreFocus(to: previousApp)
        }

        if prefs.hasNoActions {
            ToastHUD.shared.show("No after-capture action is enabled", symbol: "exclamationmark.triangle.fill", on: screen)
        } else if prefs.showConfirmation, !confirmations.isEmpty {
            ToastHUD.shared.show(confirmations.joined(separator: "  ·  "), on: screen)
        }
    }

    private static func restoreFocus(to app: NSRunningApplication?) {
        guard let app, app != NSRunningApplication.current, !app.isTerminated else { return }
        app.activate()
    }

    private func handle(_ error: Error) {
        if let captureError = error as? CaptureError, case .permissionDenied = captureError {
            Permissions.handleMissingScreenRecording()
            return
        }
        if !Permissions.hasScreenRecording {
            Permissions.handleMissingScreenRecording()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screenshot failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func showSaveError(_ error: Error, folder: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't save the screenshot"
        alert.informativeText = "\(error.localizedDescription)\n\nFolder: \(folder.path)"
        alert.runModal()
    }

    /// Brief white flash so a full-screen capture is visibly acknowledged.
    private func flash(on screen: NSScreen) {
        let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        window.backgroundColor = .white
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0.6
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }
}
