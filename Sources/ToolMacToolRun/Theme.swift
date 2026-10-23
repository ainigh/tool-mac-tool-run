import AppKit
import RunCore
import SwiftUI

/// How each grid looks wherever it's offered: its icon, its tile's colors, its key (⌘1…⌘4).
extension GridKind {
    var symbol: String {
        switch self {
        case .scripts: "terminal.fill"
        case .composer: "point.3.connected.trianglepath.dotted"
        case .utilities: "wrench.and.screwdriver.fill"
        case .browser: "globe"
        }
    }

    var colors: [Color] {
        switch self {
        case .scripts: [Color(red: 0.23, green: 0.52, blue: 0.95), Color(red: 0.36, green: 0.36, blue: 0.84)]
        case .composer: [Color(red: 0.58, green: 0.36, blue: 0.86), Color(red: 0.93, green: 0.33, blue: 0.55)]
        case .utilities: [Color(red: 0.95, green: 0.62, blue: 0.20), Color(red: 0.86, green: 0.42, blue: 0.18)]
        case .browser: [Color(red: 0.16, green: 0.68, blue: 0.86), Color(red: 0.14, green: 0.45, blue: 0.82)]
        }
    }

    /// Its key, with ⌘: its place in the list.
    var key: Character { Character(String((GridKind.allCases.firstIndex(of: self) ?? 0) + 1)) }
}

/// The one look each state has, everywhere it shows (a cell, a row in Runs, the doctor).
enum Theme {
    static func color(_ state: RunRecord.State) -> Color {
        switch state {
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        case .stopped: .gray
        case .couldNotStart: .orange
        }
    }

    static func symbol(_ state: RunRecord.State) -> String {
        switch state {
        case .running: "play.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.circle.fill"
        case .couldNotStart: "exclamationmark.triangle.fill"
        }
    }

    static func color(_ status: Doctor.Line.Status) -> Color {
        switch status {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        }
    }

    static func symbol(_ status: Doctor.Line.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }

    /// A cell's light color.
    static func tint(_ index: Int) -> Color {
        let t = GridSettings.tints[GridSettings.tints.indices.contains(index) ? index : 0]
        return Color(red: t.red, green: t.green, blue: t.blue)
    }

    /// A badge's color, per language family.
    static func badge(_ lang: ScriptLanguage) -> Color {
        switch lang {
        case .bash, .zsh, .sh, .fish: Color(red: 0.20, green: 0.45, blue: 0.30)
        case .python: Color(red: 0.20, green: 0.40, blue: 0.65)
        case .node, .typescript, .deno: Color(red: 0.70, green: 0.55, blue: 0.05)
        case .ruby: Color(red: 0.70, green: 0.15, blue: 0.15)
        case .swift: Color(red: 0.90, green: 0.40, blue: 0.20)
        case .go: Color(red: 0.10, green: 0.55, blue: 0.65)
        case .applescript: Color(red: 0.45, green: 0.45, blue: 0.50)
        case .straw: Color(red: 0.62, green: 0.48, blue: 0.12)
        default: Color(red: 0.40, green: 0.35, blue: 0.55)
        }
    }

    static let mono = Font.system(.body, design: .monospaced)

    /// How a notice about a run looks, from how the run went.
    static func tone(_ state: RunRecord.State) -> Notice.Tone {
        switch state {
        case .running: .running
        case .succeeded: .success
        case .failed: .failure
        case .stopped: .stopped
        case .couldNotStart: .warning
        }
    }

    // MARK: the shapes and surfaces every window shares

    /// Corner radii: a control, a cell, a card, a notice.
    static let radiusSmall: CGFloat = 8
    static let radiusCell: CGFloat = 16
    static let radiusCard: CGFloat = 18
    static let radiusNotice: CGFloat = 30

    /// What runs output is shown on: a terminal's dark, in light mode and dark.
    static let terminal = Color(red: 0.075, green: 0.082, blue: 0.10)
    static let terminalText = Color(white: 0.88)
    static let terminalError = Color(red: 1.0, green: 0.48, blue: 0.46)
}

/// Behind a window's content: the window's own color, with a soft wash of the accent from the top.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color.accentColor.opacity(0.10), Color.accentColor.opacity(0.0)],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
            RadialGradient(colors: [Color.purple.opacity(0.07), .clear], center: .topTrailing, startRadius: 0, endRadius: 760)
        }
        .ignoresSafeArea()
    }
}

/// A square of color with a symbol on it: what a window, a card or a notice is about.
struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(0.78), color], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: color.opacity(0.35), radius: size * 0.15, y: size * 0.06)
    }
}

/// A little label in a capsule: a state, a count, a hint.
struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary
    /// Filled with its color (white text), for what matters most on the line.
    var filled = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(filled ? Color.white : color)
        .background(Capsule().fill(filled ? color : color.opacity(0.13)))
    }
}

extension View {
    /// A raised card: a material, a hairline edge and a soft shadow.
    func card(radius: CGFloat = Theme.radiusCard, shadow: Bool = true) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(shadow ? 0.10 : 0), radius: 14, y: 5)
    }

    /// A group of small controls sharing one capsule (a stepper, the pages).
    func capsuleGroup() -> some View {
        padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The one button that's the main thing to do here: filled with color, it presses in.
struct ProminentButtonStyle: ButtonStyle {
    var color: Color = .accentColor
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, color: color, large: large)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let color: Color
        let large: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: large ? 15 : 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 20 : 14)
                .padding(.vertical, large ? 10 : 6)
                .background(
                    Capsule().fill(LinearGradient(colors: [color.opacity(hover ? 0.85 : 0.92), color],
                                                  startPoint: .top, endPoint: .bottom))
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2)))
                .shadow(color: color.opacity(configuration.isPressed ? 0.12 : 0.32), radius: configuration.isPressed ? 2 : 6, y: 2)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// A quieter button: a faint capsule that warms up under the pointer.
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint, large: large)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let large: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: large ? 15 : 13, weight: .medium))
                .foregroundStyle(tint == .primary ? Color.primary : tint)
                .padding(.horizontal, large ? 18 : 12)
                .padding(.vertical, large ? 10 : 6)
                .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.16 : hover ? 0.11 : 0.06)))
                .overlay(Capsule().strokeBorder(tint.opacity(hover ? 0.16 : 0.09)))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// A round button holding a symbol (close, step, page).
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, size: size)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hover ? 0.10 : 0.0)))
                .opacity(enabled ? 1 : 0.3)
                .contentShape(Circle())
                .onHover { hover = $0 }
        }
    }
}

/// A round button that copies, and says it did: its symbol turns to a green check for a moment.
struct CopyButton: View {
    let help: String
    var size: CGFloat = 26
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(CircleIconButtonStyle(size: size))
        .help(copied ? "Copied" : help)
        .accessibilityLabel(copied ? "Copied" : help)
    }
}

/// "just now", "2 min ago", "3 h ago", "yesterday", or the date (`RunRecord.ago`).
func ago(_ date: Date, now: Date = Date()) -> String {
    RunRecord.ago(date, now: now)
}
