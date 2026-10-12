import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One editor window for one screenshot.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: EditorModel
    private let canvas: EditorCanvasView
    private let scrollView: NSScrollView
    var onClose: ((EditorWindowController) -> Void)?

    private static let toolbarHeight: CGFloat = 50

    init(capture: CapturedImage, savedURL: URL?) {
        model = EditorModel(capture: capture)
        model.fileURL = savedURL
        canvas = EditorCanvasView(model: model)

        scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.borderType = .noBorder

        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 820, height: 360)
        super.init(window: window)
        window.delegate = self

        let actions = EditorToolbarActions(
            undo: { [weak self] in self?.canvas.undo(nil) },
            redo: { [weak self] in self?.canvas.redo(nil) },
            copy: { [weak self] in self?.copyImage() },
            save: { [weak self] in self?.save() },
            saveAs: { [weak self] in self?.saveAs() },
            revealInFinder: { [weak self] in self?.revealInFinder() },
            refocus: { [weak self] in
                guard let self, !self.canvas.isEditingText else { return }
                self.window?.makeFirstResponder(self.canvas)
            }
        )
        let toolbar = NSHostingView(rootView: EditorToolbar(model: model, actions: actions))
        let toolbarBackground = NSVisualEffectView()
        toolbarBackground.material = .titlebar
        toolbarBackground.blendingMode = .withinWindow

        let separator = NSBox()
        separator.boxType = .separator

        let content = NSView()
        for view in [toolbarBackground, toolbar, separator, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbarBackground.topAnchor.constraint(equalTo: content.topAnchor),
            toolbarBackground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbarBackground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbarBackground.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),

            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateTitle() {
        guard let window else { return }
        if let url = model.fileURL {
            window.title = url.deletingPathExtension().lastPathComponent
            window.representedURL = url
        } else {
            window.title = ImageOutput.baseFilename(prefix: Preferences.shared.filenamePrefix, date: model.captureDate)
        }
        window.subtitle = "\(model.image.width) × \(model.image.height)"
    }

    /// Sizes the window to fit the screenshot on `screen` and brings it forward.
    func present(on screen: NSScreen?) {
        guard let window else { return }
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let titlebar: CGFloat = 52
        let chromeHeight = Self.toolbarHeight + titlebar
        let canvasSize = model.canvasSize
        let maxWidth = visible.width * 0.9
        let maxHeight = visible.height * 0.9 - chromeHeight
        let fit = min(1, maxWidth / max(canvasSize.width, 1), maxHeight / max(canvasSize.height, 1))
        let contentWidth = max(window.minSize.width, canvasSize.width * fit + 2)
        let contentHeight = max(window.minSize.height - titlebar, canvasSize.height * fit + Self.toolbarHeight + 2)

        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        let origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        window.setFrame(NSRect(origin: origin, size: frame.size), display: false)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        scrollView.magnification = fit
        window.makeFirstResponder(canvas)
    }

    // MARK: Output

    @objc func copy(_ sender: Any?) {
        copyImage()
    }

    func copyImage() {
        canvas.commitTextEditing()
        guard let image = model.renderImage() else { return }
        ImageOutput.copyToClipboard(image, scale: model.scale)
        model.exportedChangeCount = model.changeCount
        ToastHUD.shared.show("Copied to clipboard", symbol: "doc.on.clipboard.fill", on: window?.screen)
    }

    @objc func saveDocument(_ sender: Any?) {
        save()
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        saveAs()
    }

    /// Saves over the existing file, or into the screenshots folder when the
    /// capture hasn't been saved yet.
    func save() {
        canvas.commitTextEditing()
        guard let image = model.renderImage() else { return }
        let prefs = Preferences.shared
        do {
            if let url = model.fileURL {
                try ImageOutput.write(image, scale: model.scale, to: url, format: ImageOutput.format(for: url))
            } else {
                model.fileURL = try ImageOutput.save(image, scale: model.scale, to: prefs.saveFolderURL,
                                                     prefix: prefs.filenamePrefix, date: model.captureDate,
                                                     format: prefs.imageFormat)
            }
            model.exportedChangeCount = model.changeCount
            updateTitle()
            ToastHUD.shared.show("Saved \(model.fileURL?.lastPathComponent ?? "")",
                                 symbol: "square.and.arrow.down.fill", on: window?.screen)
        } catch {
            presentError(error)
        }
    }

    func saveAs() {
        canvas.commitTextEditing()
        guard let window else { return }
        let prefs = Preferences.shared
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let currentURL = model.fileURL
        panel.directoryURL = currentURL?.deletingLastPathComponent() ?? prefs.saveFolderURL
        let baseName = currentURL?.deletingPathExtension().lastPathComponent
            ?? ImageOutput.baseFilename(prefix: prefs.filenamePrefix, date: model.captureDate)
        panel.nameFieldStringValue = "\(baseName).\(prefs.imageFormat.fileExtension)"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let image = self.model.renderImage() else { return }
            do {
                try ImageOutput.write(image, scale: self.model.scale, to: url, format: ImageOutput.format(for: url))
                self.model.fileURL = url
                self.model.exportedChangeCount = self.model.changeCount
                self.updateTitle()
            } catch {
                self.presentError(error)
            }
        }
    }

    func revealInFinder() {
        guard let url = model.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) {
        setMagnification(scrollView.magnification * 1.25)
    }

    @objc func zoomOut(_ sender: Any?) {
        setMagnification(scrollView.magnification / 1.25)
    }

    @objc func zoomToActualSize(_ sender: Any?) {
        setMagnification(1)
    }

    @objc func zoomToFit(_ sender: Any?) {
        let visible = scrollView.contentView.frame.size
        let size = model.canvasSize
        setMagnification(min(visible.width / max(size.width, 1), visible.height / max(size.height, 1)))
    }

    private func setMagnification(_ value: CGFloat) {
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(clamped, centeredAt: center)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(revealInFinderAction(_:)) {
            return model.fileURL != nil
        }
        return true
    }

    @objc func revealInFinderAction(_ sender: Any?) {
        revealInFinder()
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.commitTextEditing()
        guard model.hasUnexportedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "Keep your annotations?"
        alert.informativeText = "This screenshot has annotations that haven't been copied or saved."
        alert.addButton(withTitle: "Copy & Close")
        alert.addButton(withTitle: "Save & Close")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Discard")
        discard.hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.copyImage()
                sender.close()
            case .alertSecondButtonReturn:
                self.save()
                if !self.model.hasUnexportedChanges { sender.close() }
            case .alertThirdButtonReturn:
                break
            default:
                self.model.exportedChangeCount = self.model.changeCount
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

/// Keeps the image centred when it's smaller than the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let docFrame = documentView.frame
        if rect.width > docFrame.width {
            rect.origin.x = (docFrame.width - rect.width) / 2
        }
        if rect.height > docFrame.height {
            rect.origin.y = (docFrame.height - rect.height) / 2
        }
        return rect
    }
}

final class EditorWindow: NSWindow {
    // Esc with nothing selected closes the editor, like Quick Look.
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// Keeps track of open editor windows.
@MainActor
final class EditorManager {
    static let shared = EditorManager()
    private(set) var controllers: [EditorWindowController] = []
    var onWindowsChanged: (() -> Void)?

    func open(_ capture: CapturedImage, savedURL: URL?, on screen: NSScreen?) {
        let controller = EditorWindowController(capture: capture, savedURL: savedURL)
        controller.onClose = { [weak self] closed in
            guard let self else { return }
            self.controllers.removeAll { $0 === closed }
            self.onWindowsChanged?()
        }
        controllers.append(controller)
        onWindowsChanged?()
        controller.present(on: screen)
    }
}
