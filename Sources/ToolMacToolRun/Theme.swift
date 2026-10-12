import RunCore
import SwiftUI

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
        default: Color(red: 0.40, green: 0.35, blue: 0.55)
        }
    }

    static let mono = Font.system(.body, design: .monospaced)
}

/// "just now", "2 min ago", "3 h ago", "yesterday", or the date.
func ago(_ date: Date, now: Date = Date()) -> String {
    let s = now.timeIntervalSince(date)
    if s < 45 { return "just now" }
    if s < 3600 { return "\(Int((s / 60).rounded())) min ago" }
    if s < 86_400 { return "\(Int((s / 3600).rounded())) h ago" }
    if s < 172_800 { return "yesterday" }
    return date.formatted(date: .abbreviated, time: .omitted)
}
