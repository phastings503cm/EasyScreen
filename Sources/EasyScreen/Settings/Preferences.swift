import AppKit
import Combine

enum ImageFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var title: String { self == .png ? "PNG" : "JPEG" }
}

/// All user-configurable settings, persisted in `UserDefaults`.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults

    // MARK: After-capture actions (each runs independently, all at once)

    @Published var openEditor: Bool { didSet { defaults.set(openEditor, forKey: Keys.openEditor) } }
    @Published var copyToClipboard: Bool { didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) } }
    @Published var saveToFolder: Bool { didSet { defaults.set(saveToFolder, forKey: Keys.saveToFolder) } }
    @Published var saveFolderPath: String { didSet { defaults.set(saveFolderPath, forKey: Keys.saveFolderPath) } }
    @Published var imageFormat: ImageFormat { didSet { defaults.set(imageFormat.rawValue, forKey: Keys.imageFormat) } }
    @Published var filenamePrefix: String { didSet { defaults.set(filenamePrefix, forKey: Keys.filenamePrefix) } }

    // MARK: Feedback

    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Keys.playSound) } }
    @Published var showConfirmation: Bool { didSet { defaults.set(showConfirmation, forKey: Keys.showConfirmation) } }
    @Published var showMagnifier: Bool { didSet { defaults.set(showMagnifier, forKey: Keys.showMagnifier) } }

    // MARK: Shortcuts

    @Published private(set) var hotkeys: [HotkeyAction: KeyCombo]

    // MARK: Editor tool memory

    @Published var editorColor: NSColor { didSet { defaults.set(editorColor.hexString, forKey: Keys.editorColor) } }
    @Published var editorTextBackgroundColor: NSColor {
        didSet { defaults.set(editorTextBackgroundColor.hexString, forKey: Keys.editorTextBackgroundColor) }
    }
    @Published var editorLineWidth: Double { didSet { defaults.set(editorLineWidth, forKey: Keys.editorLineWidth) } }
    @Published var editorFontSize: Double { didSet { defaults.set(editorFontSize, forKey: Keys.editorFontSize) } }
    @Published var editorTextBackground: Bool {
        didSet { defaults.set(editorTextBackground, forKey: Keys.editorTextBackground) }
    }

    var hasCompletedFirstLaunch: Bool {
        get { defaults.bool(forKey: Keys.firstLaunchDone) }
        set { defaults.set(newValue, forKey: Keys.firstLaunchDone) }
    }

    var hasConfiguredLoginItem: Bool {
        get { defaults.bool(forKey: Keys.loginItemConfigured) }
        set { defaults.set(newValue, forKey: Keys.loginItemConfigured) }
    }

    var saveFolderURL: URL {
        URL(fileURLWithPath: (saveFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// True when no after-capture action is enabled, which would make a
    /// capture do nothing visible.
    var hasNoActions: Bool {
        !openEditor && !copyToClipboard && !saveToFolder
    }

    static var defaultSaveFolder: String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("EasyScreen").path
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.openEditor: true,
            Keys.copyToClipboard: true,
            Keys.saveToFolder: false,
            Keys.saveFolderPath: Preferences.defaultSaveFolder,
            Keys.imageFormat: ImageFormat.png.rawValue,
            Keys.filenamePrefix: "Screenshot",
            Keys.playSound: true,
            Keys.showConfirmation: true,
            Keys.showMagnifier: true,
            Keys.editorColor: "#FF3B30FF",
            Keys.editorTextBackgroundColor: "#FFFFFFFF",
            Keys.editorLineWidth: 4.0,
            Keys.editorFontSize: 24.0,
            Keys.editorTextBackground: true,
        ])

        openEditor = defaults.bool(forKey: Keys.openEditor)
        copyToClipboard = defaults.bool(forKey: Keys.copyToClipboard)
        saveToFolder = defaults.bool(forKey: Keys.saveToFolder)
        saveFolderPath = defaults.string(forKey: Keys.saveFolderPath) ?? Preferences.defaultSaveFolder
        imageFormat = ImageFormat(rawValue: defaults.string(forKey: Keys.imageFormat) ?? "") ?? .png
        filenamePrefix = defaults.string(forKey: Keys.filenamePrefix) ?? "Screenshot"
        playSound = defaults.bool(forKey: Keys.playSound)
        showConfirmation = defaults.bool(forKey: Keys.showConfirmation)
        showMagnifier = defaults.bool(forKey: Keys.showMagnifier)
        editorColor = NSColor(hexString: defaults.string(forKey: Keys.editorColor) ?? "") ?? .systemRed
        editorTextBackgroundColor = NSColor(hexString: defaults.string(forKey: Keys.editorTextBackgroundColor) ?? "")
            ?? .white
        editorLineWidth = defaults.double(forKey: Keys.editorLineWidth)
        editorFontSize = defaults.double(forKey: Keys.editorFontSize)
        editorTextBackground = defaults.bool(forKey: Keys.editorTextBackground)
        hotkeys = Preferences.loadHotkeys(from: defaults)
    }

    // MARK: Hotkey storage

    func hotkey(for action: HotkeyAction) -> KeyCombo? {
        hotkeys[action]
    }

    func setHotkey(_ combo: KeyCombo?, for action: HotkeyAction) {
        var updated = hotkeys
        if let combo {
            // A combo can only drive one action; steal it from any other.
            for (other, existing) in updated where other != action && existing == combo {
                updated[other] = nil
            }
            updated[action] = combo
        } else {
            updated[action] = nil
        }
        hotkeys = updated
        saveHotkeys()
    }

    func resetHotkeys() {
        hotkeys = Preferences.defaultHotkeys
        saveHotkeys()
    }

    static let defaultHotkeys: [HotkeyAction: KeyCombo] = [
        .captureRegion: .defaultRegion
    ]

    private func saveHotkeys() {
        // Store every action explicitly (with `null` for "no shortcut") so that
        // clearing a default shortcut survives relaunches.
        var stored: [String: KeyCombo?] = [:]
        for action in HotkeyAction.allCases {
            stored[action.rawValue] = hotkeys[action]
        }
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Keys.hotkeys)
        }
    }

    private static func loadHotkeys(from defaults: UserDefaults) -> [HotkeyAction: KeyCombo] {
        guard let data = defaults.data(forKey: Keys.hotkeys),
              let stored = try? JSONDecoder().decode([String: KeyCombo?].self, from: data)
        else { return defaultHotkeys }

        var result: [HotkeyAction: KeyCombo] = [:]
        for action in HotkeyAction.allCases {
            if let entry = stored[action.rawValue] {
                if let combo = entry { result[action] = combo }
            } else if let fallback = defaultHotkeys[action] {
                // Actions added in newer versions get their default.
                result[action] = fallback
            }
        }
        return result
    }

    private enum Keys {
        static let openEditor = "openEditor"
        static let copyToClipboard = "copyToClipboard"
        static let saveToFolder = "saveToFolder"
        static let saveFolderPath = "saveFolderPath"
        static let imageFormat = "imageFormat"
        static let filenamePrefix = "filenamePrefix"
        static let playSound = "playSound"
        static let showConfirmation = "showConfirmation"
        static let showMagnifier = "showMagnifier"
        static let hotkeys = "hotkeys.v1"
        static let editorColor = "editor.color"
        static let editorTextBackgroundColor = "editor.textBackgroundColor"
        static let editorLineWidth = "editor.lineWidth"
        static let editorFontSize = "editor.fontSize"
        static let editorTextBackground = "editor.textBackground"
        static let firstLaunchDone = "firstLaunchDone"
        static let loginItemConfigured = "loginItemConfigured"
    }
}

// MARK: - Color <-> hex

extension NSColor {
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if hex.count == 6 {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        } else {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        // Pattern/catalog colors can't report RGB components (that raises);
        // fall back to black rather than crashing.
        guard let c = usingColorSpace(.sRGB) else { return "#000000FF" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = Int((c.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
