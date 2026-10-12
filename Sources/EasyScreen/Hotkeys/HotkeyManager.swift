import AppKit
import Carbon.HIToolbox

/// Actions that can be bound to a global keyboard shortcut.
enum HotkeyAction: String, CaseIterable, Identifiable {
    case captureRegion
    case captureFullScreen
    case openSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureRegion: return "Capture region"
        case .captureFullScreen: return "Capture full screen"
        case .openSettings: return "Open settings"
        }
    }

    fileprivate var carbonID: UInt32 {
        switch self {
        case .captureRegion: return 1
        case .captureFullScreen: return 2
        case .openSettings: return 3
        }
    }

    fileprivate init?(carbonID: UInt32) {
        guard let match = HotkeyAction.allCases.first(where: { $0.carbonID == carbonID }) else { return nil }
        self = match
    }
}

/// Registers system-wide hotkeys through the Carbon Event Manager.
///
/// `RegisterEventHotKey` is still the only public API that delivers global
/// shortcuts without requiring Accessibility / Input Monitoring permission.
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    /// Actions whose shortcut could not be registered (usually because another
    /// app already owns that key combination).
    @Published private(set) var failedActions: Set<HotkeyAction> = []

    var onTrigger: ((HotkeyAction) -> Void)?

    private var registered: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var isSuspended = false
    private var lastBindings: [HotkeyAction: KeyCombo] = [:]

    private static let signature: OSType = {
        // 'EzSc'
        let chars: [UInt8] = Array("EzSc".utf8)
        return chars.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    private init() {
        installHandler()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotkeyManager.signature,
                  let action = HotkeyAction(carbonID: hotKeyID.id)
            else { return OSStatus(eventNotHandledErr) }

            DispatchQueue.main.async {
                HotkeyManager.shared.onTrigger?(action)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandler)
    }

    /// Replaces all registrations with the given bindings.
    func apply(bindings: [HotkeyAction: KeyCombo]) {
        lastBindings = bindings
        guard !isSuspended else { return }
        unregisterAll()

        var failures: Set<HotkeyAction> = []
        for (action, combo) in bindings {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: action.carbonID)
            let status = RegisterEventHotKey(
                combo.keyCode,
                combo.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                OptionBits(0),
                &ref
            )
            if status == noErr, let ref {
                registered[action] = ref
            } else {
                failures.insert(action)
            }
        }
        if failures != failedActions {
            failedActions = failures
        }
    }

    /// Temporarily disables all hotkeys, e.g. while the user records a new one
    /// so that pressing the current shortcut doesn't trigger a capture.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        apply(bindings: lastBindings)
    }

    private func unregisterAll() {
        for ref in registered.values {
            UnregisterEventHotKey(ref)
        }
        registered.removeAll()
    }
}
