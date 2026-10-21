import AppKit
import RunCore
import SwiftUI

/// The Flow guide (docs/FLOW-GUIDE.md, carried inside the app), then every builtin function as
/// the language itself lists them (so the two can't disagree).
struct GuideView: View {
    private let blocks = MarkdownBlocks.parse(GuideView.loadGuide())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.indices), id: \.self) { i in
                    BlockView(block: blocks[i])
                }
                Divider().padding(.vertical, 8)
                Text("Every function, as the language has them").font(.title.weight(.semibold))
                Text("Read from the language itself, so this list is always the one your flows get.")
                    .foregroundStyle(.secondary)
                ForEach(Array(groups.indices), id: \.self) { g in
                    Text(groups[g].0).font(.title2.weight(.semibold)).padding(.top, 8)
                    ForEach(groups[g].1, id: \.name) { b in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(b.name).font(.body.monospaced().weight(.bold))
                                Text(": \(b.signature)").font(.body.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(b.summary)
                            CodeBlock(text: b.example)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var groups: [(String, [Builtin])] {
        var order: [String] = []
        var by: [String: [Builtin]] = [:]
        for b in Builtin.all {
            if by[b.group] == nil { order.append(b.group) }
            by[b.group, default: []].append(b)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    nonisolated static func loadGuide() -> String {
        if let url = Bundle.main.url(forResource: "FLOW-GUIDE", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "# The Flow guide\n\nThe full guide is docs/FLOW-GUIDE.md in the app's repository (this copy of the app was built without it). Every function is listed below."
    }
}

/// The pieces of a Markdown page this guide uses: headings, paragraphs, lists, code and tables.
enum MarkdownBlocks {
    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case code(String)
        case table([String])
        case rule
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [String] = []
        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func endTable() {
            if !table.isEmpty { blocks.append(.table(table)) }
            table = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if line.hasPrefix("```") {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(raw)
                }
                continue
            }
            if line.hasPrefix("```") {
                endParagraph(); endTable()
                code = []
            } else if line.hasPrefix("|") {
                endParagraph()
                // The |---|---| line under a table's header isn't shown.
                if !line.allSatisfy({ "|-: ".contains($0) }) { table.append(line) }
            } else if line.hasPrefix("#") {
                endParagraph(); endTable()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                endParagraph(); endTable()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if line == "---" {
                endParagraph(); endTable()
                blocks.append(.rule)
            } else if line.isEmpty {
                endParagraph(); endTable()
            } else if let n = line.firstIndex(of: "."), line[..<n].allSatisfy(\.isNumber), !line[..<n].isEmpty {
                endParagraph(); endTable()
                blocks.append(.bullet(line))
            } else {
                endTable()
                paragraph.append(line)
            }
        }
        endParagraph(); endTable()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    /// A table row's cells (a \\| inside a cell is a | of its own).
    static func cells(_ row: String) -> [String] {
        row.replacingOccurrences(of: "\\|", with: "\u{1}")
            .split(separator: "|")
            .map { $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

private struct BlockView: View {
    let block: MarkdownBlocks.Block

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownBlocks.inline(text))
                .font(level == 1 ? .largeTitle.weight(.bold) : level == 2 ? .title.weight(.semibold) : .title3.weight(.semibold))
                .padding(.top, level == 1 ? 0 : 10)
        case let .paragraph(text):
            Text(MarkdownBlocks.inline(text)).fixedSize(horizontal: false, vertical: true)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(MarkdownBlocks.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
        case let .code(text):
            CodeBlock(text: text)
        case let .table(rows):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.indices), id: \.self) { i in
                    let cells = MarkdownBlocks.cells(rows[i])
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(cells.indices), id: \.self) { c in
                            Text(MarkdownBlocks.inline(cells[c]))
                                .fontWeight(i == 0 ? .semibold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if i == 0 { Divider() }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
        case .rule:
            Divider()
        }
    }
}

/// Code, in a box, with a copy button.
struct CodeBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)  // a line of it can be picked, not only all of it
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(help: "Copy the code", size: 22) { text }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}
