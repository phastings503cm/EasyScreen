import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Captures the next key combination typed while recording.
final class ShortcutRecorderState: ObservableObject {
    @Published var isRecording = false
    @Published var liveModifiers: NSEvent.ModifierFlags = []
    @Published var message: String?

    private var monitor: Any?
    private var onRecord: ((KeyCombo?) -> Void)?
    /// When a click ended recording; that same click must not restart it.
    private(set) var stoppedByClickAt: Date?

    func start(onRecord: @escaping (KeyCombo?) -> Void) {
        stop()
        self.onRecord = onRecord
        isRecording = true
        message = nil
        liveModifiers = []
        HotkeyManager.shared.suspend()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .flagsChanged:
                self.liveModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                return nil
            case .leftMouseDown:
                // Clicking anywhere ends recording without changes.
                self.stoppedByClickAt = Date()
                self.stop()
                return event
            default:
                return self.handle(keyDown: event)
            }
        }
    }

    private func handle(keyDown event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case kVK_Escape where flags.isEmpty:
            stop()
            return nil
        case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
            finish(with: nil)
            return nil
        default:
            break
        }

        let combo = KeyCombo(keyCode: event.keyCode, modifierFlags: flags)
        guard combo.isValidGlobalHotkey else {
            NSSound.beep()
            message = "Include ⌘, ⌥ or ⌃ in the shortcut"
            return nil
        }
        finish(with: combo)
        return nil
    }

    private func finish(with combo: KeyCombo?) {
        let callback = onRecord
        stop()
        callback?(combo)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecord = nil
        if isRecording {
            isRecording = false
            HotkeyManager.shared.resume()
        }
        liveModifiers = []
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

struct ShortcutRecorder: View {
    let combo: KeyCombo?
    let onChange: (KeyCombo?) -> Void

    @StateObject private var state = ShortcutRecorderState()

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if state.isRecording {
                    state.stop()
                } else if let stopped = state.stoppedByClickAt, Date().timeIntervalSince(stopped) < 0.6 {
                    // This click already ended a recording session.
                } else {
                    state.start { onChange($0) }
                }
            } label: {
                Text(label)
                    .font(.system(size: 12, weight: combo == nil && !state.isRecording ? .regular : .medium,
                                  design: .rounded))
                    .foregroundStyle(state.isRecording ? Color.accentColor : (combo == nil ? .secondary : .primary))
                    .frame(minWidth: 120)
            }
            .help(state.isRecording ? "Type a shortcut · Esc cancels · ⌫ clears" : "Click to record a new shortcut")

            if combo != nil && !state.isRecording {
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let message = state.message, state.isRecording {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize()
                    .offset(y: 16)
            }
        }
        .onDisappear { state.stop() }
    }

    private var label: String {
        if state.isRecording {
            let mods = KeyCombo(keyCode: 0, modifiers: KeyCombo.carbonModifiers(from: state.liveModifiers)).modifierSymbols
            return mods.isEmpty ? "Type shortcut…" : mods + "…"
        }
        return combo?.displayString ?? "Record Shortcut"
    }
}
