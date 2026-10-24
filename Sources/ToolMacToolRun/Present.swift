import AppKit
import RunCore
import SwiftUI

/// What's been shown to the person (by another app, through `/api/present` or "present": true, or
/// from a board): the latest in a window in front of everything, the ones before it a click away.
@MainActor
final class PresentCenter: ObservableObject {
    static let shared = PresentCenter()

    /// The latest first (at most 20).
    @Published private(set) var shown: [Shown] = []
    /// The one in the window.
    @Published var current: UUID?

    struct Shown: Identifiable {
        let id = UUID()
        let p: Presentation
        let at = Date()
    }

    var front: Shown? { shown.first { $0.id == current } ?? shown.first }

    /// Shows it, in front of everything.
    func show(_ p: Presentation) {
        let s = Shown(p: p)
        shown.insert(s, at: 0)
        if shown.count > 20 { shown.removeLast(shown.count - 20) }
        current = s.id
        Windows.showPresent()
    }

    /// Puts text on the clipboard for another app (the API's log keeps who, and when).
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The window: what's shown, where it's from and who asked, laid out, with copy buttons (the
/// whole, each section, each piece of code; for the mind, each line).
struct PresentView: View {
    @ObservedObject var center: PresentCenter
    @State private var raw = false

    var body: some View {
        VStack(spacing: 0) {
            if let s = center.front {
                header(s)
                    .padding(.horizontal, 20)
                    .padding(.top, 34)
                    .padding(.bottom, 10)
                Divider()
                ScrollView {
                    content(s.p)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(s.id)
                .background(Color(nsColor: .textBackgroundColor))
                Divider()
                footer(s)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            } else {
                Text("Nothing has been shown yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Backdrop())
    }

    private func header(_ s: PresentCenter.Shown) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol(s.p), color: s.p.format == .mind ? Board.mind.colors[0] : Color.accentColor, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.p.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(byline(s))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let why = s.p.why {
                    Text("“\(why)”")
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            if s.p.format == .markdown {
                Picker("", selection: $raw) {
                    Text("Laid Out").tag(false)
                    Text("As Written").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button { copy(s.p.text) } label: { Label("Copy All", systemImage: "doc.on.doc") }
                .buttonStyle(ProminentButtonStyle())
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy all of it (⇧⌘C)")
        }
    }

    private func symbol(_ p: Presentation) -> String {
        switch p.format {
        case .mind: Board.mind.symbol
        case .json: "curlybraces"
        case .text: "text.alignleft"
        case .markdown: p.shelf.map { Board.of($0).symbol } ?? "doc.richtext"
        }
    }

    private func byline(_ s: PresentCenter.Shown) -> String {
        var parts: [String] = []
        if let source = s.p.source { parts.append(source) }
        parts.append(s.p.client == "You" ? "shown \(RunRecord.ago(s.at))" : "shown by \(s.p.client), \(RunRecord.ago(s.at))")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func content(_ p: Presentation) -> some View {
        switch p.format {
        case .markdown:
            if raw {
                Text(p.text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                MarkdownDocument(text: p.text)
            }
        case .mind:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(p.text.components(separatedBy: "\n").filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("|") ? Color.primary : Color.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(help: "Copy this line", size: 20) { line }
                    }
                }
            }
        case .json, .text:
            CodeBlock(text: p.text)
        }
    }

    private func footer(_ s: PresentCenter.Shown) -> some View {
        HStack(spacing: 8) {
            if let shelf = s.p.shelf {
                Button { Windows.showShelfBoard(shelf) } label: { Label("Open \(shelf.title)", systemImage: Board.of(shelf).symbol) }
                    .buttonStyle(SoftButtonStyle())
                    .help("Its board, to edit it or see the rest")
                if let name = s.p.name, let note = FileLibrary(shelf: shelf).find(name) {
                    Button { NSWorkspace.shared.open(note.url) } label: { Label("Open in Its App", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(SoftButtonStyle())
                }
            }
            if s.p.format == .mind {
                Button { Windows.showMindBoard() } label: { Label("Open the Mind", systemImage: Board.mind.symbol) }
                    .buttonStyle(SoftButtonStyle())
            }
            Spacer()
            if center.shown.count > 1 {
                Menu {
                    ForEach(center.shown) { other in
                        Button("\(other.p.title) — \(RunRecord.ago(other.at))") { center.current = other.id }
                    }
                } label: {
                    Label("Shown Before (\(center.shown.count - 1))", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text("\(s.p.text.count) characters")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
