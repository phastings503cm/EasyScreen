import AppKit
import SwiftUI

struct EditorToolbarActions {
    var undo: () -> Void
    var redo: () -> Void
    var copy: () -> Void
    var save: () -> Void
    var saveAs: () -> Void
    var revealInFinder: (() -> Void)?
    /// Returns keyboard focus to the canvas after a toolbar click.
    var refocus: () -> Void
}

struct EditorToolbar: View {
    @ObservedObject var model: EditorModel
    var actions: EditorToolbarActions

    private var hasFile: Bool { model.fileURL != nil }

    private static let swatches: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // purple
        NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1), // black
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // white
    ]

    var body: some View {
        HStack(spacing: 10) {
            toolPicker
            divider
            colorRow
            divider
            styleControls
            Spacer(minLength: 6)
            historyButtons
            outputButtons
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .controlSize(.regular)
    }

    private var divider: some View {
        Divider().frame(height: 24)
    }

    private var toolPicker: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    model.tool = tool
                    actions.refocus()
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ToolButtonStyle(isSelected: model.tool == tool))
                .help("\(tool.title) (\(String(tool.shortcut).uppercased()))")
                .accessibilityLabel(tool.title)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }

    private var colorRow: some View {
        HStack(spacing: 5) {
            ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                let isSelected = swatch.hexString == model.color.hexString
                Button {
                    model.color = swatch
                    actions.refocus()
                } label: {
                    Circle()
                        .fill(Color(nsColor: swatch))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                        .frame(width: 16, height: 16)
                        .padding(2)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(swatch.hexString)
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: model.color) },
                set: { model.color = NSColor($0) }
            ), supportsOpacity: true)
            .labelsHidden()
            .help("Custom color")
        }
    }

    @ViewBuilder
    private var styleControls: some View {
        if model.showsTextControls {
            HStack(spacing: 6) {
                Image(systemName: "textformat.size").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(model.fontSize) }, set: { model.fontSize = CGFloat($0.rounded()) }),
                       in: 10...120)
                    .frame(width: 90)
                Text("\(Int(model.fontSize))")
                    .monospacedDigit()
                    .frame(width: 26, alignment: .leading)
                    .foregroundStyle(.secondary)
                Toggle(isOn: $model.textBackground) {
                    Label("Background", systemImage: model.textBackground ? "character.textbox" : "character")
                }
                .toggleStyle(.button)
                .labelStyle(.titleAndIcon)
                .help("Draw the text on a solid label, or as plain outlined text")
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: model.textBackgroundColor) },
                    set: { model.textBackgroundColor = NSColor($0) }
                ), supportsOpacity: true)
                .labelsHidden()
                .disabled(!model.textBackground)
                .help("Label background color")
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(model.lineWidth) }, set: { model.lineWidth = CGFloat($0.rounded()) }),
                       in: 1...24)
                    .frame(width: 100)
                Text("\(Int(model.lineWidth))")
                    .monospacedDigit()
                    .frame(width: 22, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
            .help("Line thickness")
        }
    }

    private var historyButtons: some View {
        HStack(spacing: 2) {
            Button(action: actions.undo) {
                Image(systemName: "arrow.uturn.backward").frame(width: 22)
            }
            .disabled(!model.canUndo)
            .help("Undo (⌘Z)")
            Button(action: actions.redo) {
                Image(systemName: "arrow.uturn.forward").frame(width: 22)
            }
            .disabled(!model.canRedo)
            .help("Redo (⇧⌘Z)")
        }
        .buttonStyle(.borderless)
    }

    private var outputButtons: some View {
        HStack(spacing: 6) {
            Button(action: actions.copy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the annotated image to the clipboard (⌘C)")

            Button(action: actions.save) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .help(hasFile ? "Save over the captured file (⌘S)" : "Save to your screenshots folder (⌘S)")

            Menu {
                Button("Save As…", action: actions.saveAs)
                if let reveal = actions.revealInFinder {
                    Button("Show in Finder", action: reveal).disabled(!hasFile)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }
}

private struct ToolButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
            )
    }
}
