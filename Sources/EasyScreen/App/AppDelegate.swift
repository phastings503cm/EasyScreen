import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let prefs = Preferences.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfAlreadyRunning() { return }

        NSApp.mainMenu = MainMenu.build()
        setUpStatusItem()

        HotkeyManager.shared.onTrigger = { [weak self] action in
            self?.perform(action)
        }
        prefs.$hotkeys
            .sink { HotkeyManager.shared.apply(bindings: $0) }
            .store(in: &cancellables)

        EditorManager.shared.onWindowsChanged = { [weak self] in self?.updateActivationPolicy() }
        SettingsWindowController.shared.onVisibilityChanged = { [weak self] in self?.updateActivationPolicy() }

        if !prefs.hasCompletedFirstLaunch {
            prefs.hasCompletedFirstLaunch = true
            runFirstLaunchSetup()
        }
        configureLoginItemOnce()
        Permissions.requestAfterResetIfNeeded()
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows Settings,
    /// since there's no other window to bring forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Actions

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureRegion: CaptureCoordinator.shared.captureRegion()
        case .captureFullScreen: CaptureCoordinator.shared.captureFullScreen()
        case .openSettings: SettingsWindowController.shared.show()
        }
    }

    @objc func captureRegionFromMenu(_ sender: Any?) {
        // Let the menu finish closing so it isn't in the frozen screenshot.
        CaptureCoordinator.shared.captureRegion(delay: 0.25)
    }

    @objc func captureFullScreenFromMenu(_ sender: Any?) {
        CaptureCoordinator.shared.captureFullScreen(delay: 0.25)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Free, open-source screenshots for macOS.\n\(AppInfo.repositoryURL.absoluteString)",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }

    /// Opens an existing image in the editor for annotation.
    @objc func openImage(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.directoryURL = prefs.saveFolderURL
        panel.message = "Choose images to annotate"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            openImageFile(url)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for path in filenames {
            openImageFile(URL(fileURLWithPath: path))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    private func openImageFile(_ url: URL) {
        guard let capture = CapturedImage.load(from: url) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't open “\(url.lastPathComponent)”"
            alert.informativeText = "The file isn't an image EasyScreen can read."
            alert.runModal()
            return
        }
        EditorManager.shared.open(capture, savedURL: url, on: NSScreen.main)
    }

    @objc func toggleOpenEditor(_ sender: Any?) { prefs.openEditor.toggle() }
    @objc func toggleCopyToClipboard(_ sender: Any?) { prefs.copyToClipboard.toggle() }
    @objc func toggleSaveToFolder(_ sender: Any?) { prefs.saveToFolder.toggle() }

    @objc func openSaveFolder(_ sender: Any?) {
        let url = prefs.saveFolderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "EasyScreen")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "EasyScreen"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()

        let region = menu.addItem(withTitle: "Capture Region", action: #selector(captureRegionFromMenu(_:)), keyEquivalent: "")
        region.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        applyShortcut(prefs.hotkey(for: .captureRegion), to: region)

        let full = menu.addItem(withTitle: "Capture Full Screen", action: #selector(captureFullScreenFromMenu(_:)), keyEquivalent: "")
        full.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        applyShortcut(prefs.hotkey(for: .captureFullScreen), to: full)

        menu.addItem(.separator())
        let header = NSMenuItem.sectionHeader(title: "After Capture")
        menu.addItem(header)
        addToggle(to: menu, title: "Open in Editor", isOn: prefs.openEditor, action: #selector(toggleOpenEditor(_:)))
        addToggle(to: menu, title: "Copy to Clipboard", isOn: prefs.copyToClipboard, action: #selector(toggleCopyToClipboard(_:)))
        addToggle(to: menu, title: "Save to Folder", isOn: prefs.saveToFolder, action: #selector(toggleSaveToFolder(_:)))

        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Open Image…", action: #selector(openImage(_:)), keyEquivalent: "")
        open.target = self
        let folder = menu.addItem(withTitle: "Open Screenshots Folder", action: #selector(openSaveFolder(_:)), keyEquivalent: "")
        folder.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        applyShortcut(prefs.hotkey(for: .openSettings), to: settings)
        let about = menu.addItem(withTitle: "About EasyScreen", action: #selector(showAbout(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit EasyScreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        for item in [region, full, settings, about] {
            item.target = self
        }
        if !Permissions.hasScreenRecording {
            menu.insertItem(.separator(), at: 0)
            let warn = NSMenuItem(title: "Grant Screen Recording Permission…",
                                  action: #selector(grantPermission(_:)), keyEquivalent: "")
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            warn.target = self
            menu.insertItem(warn, at: 0)
        }
    }

    @objc private func grantPermission(_ sender: Any?) {
        Permissions.presentScreenRecordingAlert()
    }

    private func addToggle(to menu: NSMenu, title: String, isOn: Bool, action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.state = isOn ? .on : .off
        item.target = self
    }

    private func applyShortcut(_ combo: KeyCombo?, to item: NSMenuItem) {
        guard let combo, let key = combo.menuKeyEquivalent else {
            item.keyEquivalent = ""
            return
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = combo.modifierFlags
    }

    // MARK: Activation policy

    /// Show a Dock icon (and menu bar) only while an editor or Settings is open.
    private func updateActivationPolicy() {
        let hasWindows = !EditorManager.shared.controllers.isEmpty || SettingsWindowController.shared.isVisible
        let desired: NSApplication.ActivationPolicy = hasWindows ? .regular : .accessory
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
            if desired == .regular { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    // MARK: First launch

    /// Starts EasyScreen at login by default — once, the first time it runs
    /// from a stable location (not a mounted DMG or Downloads). After that
    /// the Settings toggle is the source of truth.
    private func configureLoginItemOnce() {
        guard !prefs.hasConfiguredLoginItem, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        prefs.hasConfiguredLoginItem = true
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    private func runFirstLaunchSetup() {
        if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecording()
        }
        SettingsWindowController.shared.show()
        ToastHUD.shared.show("EasyScreen is in your menu bar — press \(KeyCombo.defaultRegion.displayString) to capture",
                             symbol: "camera.viewfinder")
    }

    private func terminateIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        guard let existing = others.first else { return false }
        existing.activate()
        NSApp.terminate(nil)
        return true
    }
}

enum MainMenu {
    /// The menu bar shown while an editor / Settings window is in front. It
    /// also provides the standard key equivalents (⌘C, ⌘Z, ⌘S, …).
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About EasyScreen", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide EasyScreen", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit EasyScreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "EasyScreen", to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Capture Region", action: #selector(AppDelegate.captureRegionFromMenu(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Capture Full Screen", action: #selector(AppDelegate.captureFullScreenFromMenu(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Open Image…", action: #selector(AppDelegate.openImage(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Save As…", action: #selector(EditorWindowController.saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Show in Finder", action: #selector(EditorWindowController.revealInFinderAction(_:)), keyEquivalent: "")
        add(file, title: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: "Edit", to: main)

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Actual Size", action: #selector(EditorWindowController.zoomToActualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom to Fit", action: #selector(EditorWindowController.zoomToFit(_:)), keyEquivalent: "9")
        view.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(EditorWindowController.zoomOut(_:)), keyEquivalent: "-")
        add(view, title: "View", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ submenu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
