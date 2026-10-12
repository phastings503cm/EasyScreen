import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut expressed as a virtual key code plus Carbon modifier flags.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = KeyCombo.carbonModifiers(from: modifierFlags)
    }

    /// ⌘⇧1 — the default "capture region" shortcut.
    static let defaultRegion = KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey))

    // MARK: - Modifier conversion

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// True when the combo has at least one of ⌘ ⌃ ⌥ (Shift alone is not enough
    /// for a global shortcut, it would swallow ordinary typing).
    var hasRequiredModifier: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    var isFunctionKey: Bool {
        KeyCombo.functionKeyCodes.contains(Int(keyCode))
    }

    /// Whether this combo is acceptable as a global hotkey.
    var isValidGlobalHotkey: Bool {
        hasRequiredModifier || isFunctionKey
    }

    // MARK: - Display

    var modifierSymbols: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    var keyName: String {
        KeyCombo.name(forKeyCode: Int(keyCode))
    }

    var displayString: String {
        modifierSymbols + keyName
    }

    /// A string usable as an `NSMenuItem.keyEquivalent`, or nil for keys that
    /// menus can't display.
    var menuKeyEquivalent: String? {
        if let special = KeyCombo.menuSpecialKeys[Int(keyCode)] {
            return special
        }
        let name = KeyCombo.translatedCharacter(forKeyCode: Int(keyCode))
        guard let name, name.count == 1 else { return nil }
        return name.lowercased()
    }

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "?⃝",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_ANSI_Keypad0: "Num0", kVK_ANSI_Keypad1: "Num1", kVK_ANSI_Keypad2: "Num2",
        kVK_ANSI_Keypad3: "Num3", kVK_ANSI_Keypad4: "Num4", kVK_ANSI_Keypad5: "Num5",
        kVK_ANSI_Keypad6: "Num6", kVK_ANSI_Keypad7: "Num7", kVK_ANSI_Keypad8: "Num8",
        kVK_ANSI_Keypad9: "Num9", kVK_ANSI_KeypadDecimal: "Num.", kVK_ANSI_KeypadMultiply: "Num*",
        kVK_ANSI_KeypadPlus: "Num+", kVK_ANSI_KeypadMinus: "Num-", kVK_ANSI_KeypadDivide: "Num/",
        kVK_ANSI_KeypadEquals: "Num=", kVK_ANSI_KeypadClear: "⌧",
    ]

    private static let menuSpecialKeys: [Int: String] = {
        func ch(_ v: Int) -> String { String(Character(UnicodeScalar(v)!)) }
        return [
            kVK_Return: "\r", kVK_Tab: "\t", kVK_Space: " ", kVK_Delete: ch(NSBackspaceCharacter),
            kVK_Escape: "\u{1b}", kVK_ForwardDelete: ch(NSDeleteFunctionKey),
            kVK_LeftArrow: ch(NSLeftArrowFunctionKey), kVK_RightArrow: ch(NSRightArrowFunctionKey),
            kVK_UpArrow: ch(NSUpArrowFunctionKey), kVK_DownArrow: ch(NSDownArrowFunctionKey),
            kVK_F1: ch(NSF1FunctionKey), kVK_F2: ch(NSF2FunctionKey), kVK_F3: ch(NSF3FunctionKey),
            kVK_F4: ch(NSF4FunctionKey), kVK_F5: ch(NSF5FunctionKey), kVK_F6: ch(NSF6FunctionKey),
            kVK_F7: ch(NSF7FunctionKey), kVK_F8: ch(NSF8FunctionKey), kVK_F9: ch(NSF9FunctionKey),
            kVK_F10: ch(NSF10FunctionKey), kVK_F11: ch(NSF11FunctionKey), kVK_F12: ch(NSF12FunctionKey),
        ]
    }()

    static func name(forKeyCode keyCode: Int) -> String {
        if let special = specialKeyNames[keyCode] {
            return special
        }
        if let translated = translatedCharacter(forKeyCode: keyCode), !translated.isEmpty {
            return translated.uppercased()
        }
        return "Key\(keyCode)"
    }

    /// Translates a virtual key code into the character it produces on the
    /// user's current keyboard layout (so AZERTY/Dvorak users see the right key).
    static func translatedCharacter(forKeyCode keyCode: Int) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
