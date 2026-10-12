import AppKit
import RunCore
import SwiftUI

// The block editor: a flow as a column of steps, like Apple's Shortcuts. The library on the right
// has your scripts and every kind of step; click one to add it (after the step picked), or drag it
// to where it goes. Drag a step's title to move it. Each step's settings are on its card; values
// from earlier steps go in with the ⊕ beside a field. Everything is written as Flow as you go
// (the Flow Code tab shows it), saved, and checked: a step with a mistake is outlined in red, with
// the fix under it. While the flow runs, each step shows how it went.

/// What the cards and the library color each group of steps.
enum BlockStyle {
    static func color(_ group: BlockGroup) -> Color {
        switch group {
        case .scripts: Color(red: 0.20, green: 0.47, blue: 0.95)
        case .epa: Color(red: 0.86, green: 0.26, blue: 0.42)
        case .ask: Color(red: 0.96, green: 0.55, blue: 0.10)
        case .tell: Color(red: 0.10, green: 0.65, blue: 0.70)
        case .values: Color(red: 0.80, green: 0.60, blue: 0.08)
        case .logic: Color(red: 0.45, green: 0.42, blue: 0.70)
        case .other: Color(red: 0.50, green: 0.52, blue: 0.56)
        }
    }

    static func color(_ type: BlockType) -> Color { color(type.info.group) }

    /// The small colored tile with a step's symbol (or another, for an EPA command).
    static func tile(_ type: BlockType, size: CGFloat = 26, symbol: String? = nil) -> some View {
        Image(systemName: symbol ?? type.info.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color(type)))
    }
}

/// The blocks, the check's word on them, and the run's output, with the library beside them.
struct BlockEditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var runs: RunStore
    var showOutput: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                BlockCanvas(model: model, runs: runs)
                CheckBar(model: model)
                if showOutput, let run = runs.latest(file: model.item.id, kind: model.kind) {
                    Divider()
                    OutputPanel(run: run, runs: runs)
                        .frame(height: 190)
                }
            }
            Divider()
            BlockLibrary(model: model)
                .frame(width: 290)
        }
    }
}

/// Under the blocks: whether the flow is ready to run, or what's wrong (and a click to the step).
struct CheckBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.check {
            case .none:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(model.doc.blocks.isEmpty ? "Empty: add a step from the right." : "Ready to run. Every step checks out.")
                    .foregroundStyle(.secondary)
            case let .problem(e):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(e.message).lineLimit(2).help(e.fix.map { "→ \($0)" } ?? e.message)
                if let id = model.problemBlock {
                    Button("Show the Step") { model.selected = id }
                        .buttonStyle(.link)
                }
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

/// The column of steps.
struct BlockCanvas: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var runs: RunStore

    var body: some View {
        let status = stepStatus()
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SummaryField(model: model)
                        .padding(.bottom, 14)
                    if model.doc.blocks.isEmpty {
                        EmptyBlocks(model: model)
                    }
                    BlockList(model: model, blocks: model.doc.blocks, parent: nil, branch: .body, status: status)
                    Color.clear.frame(height: 120)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selected = nil
                            model.insertionSlot = nil
                        }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.selected) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onDeleteCommand {
            if let id = model.selected { model.remove(id) }
        }
    }

    /// How each step went in the flow's latest run (the step a block runs, by its line).
    private func stepStatus() -> [UUID: RunRecord] {
        guard let run = runs.latest(file: model.item.id, kind: model.kind), let written = model.written else { return [:] }
        var map: [UUID: RunRecord] = [:]
        for step in runs.steps(of: run.id) {
            guard let line = step.line, let id = written.block(atLine: line) else { continue }
            map[id] = step
        }
        return map
    }
}

/// The line describing the flow (its first comment; shown on its cell).
struct SummaryField: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            TextField("What this flow does, in a line (it's shown on its cell)", text: model.summaryBinding)
                .textFieldStyle(.plain)
                .font(.title3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .help("The first line of the flow: what it does, as its cell on the Composer grid shows it")
    }
}

/// A flow with no steps yet: what to do first.
struct EmptyBlocks: View {
    @ObservedObject var model: EditorModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Build the flow one step at a time")
                .font(.title3.weight(.semibold))
            Text("Click a script or an action on the right to add it here, or drag it in. Steps run top to bottom; each step's output can be used by the steps after it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            if let first = model.app.scripts.first {
                Button {
                    model.add(.runScript, script: model.runName(first))
                } label: {
                    Label("Start with Run \(first.title)", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .dropDestination(for: String.self) { items, _ in
            items.first.map { model.drop($0, at: BlockSlot(parent: nil, index: 0)) } ?? false
        } isTargeted: { targeted = $0 }
    }
}

/// Steps one after another, with a place to drop between each.
struct BlockList: View {
    @ObservedObject var model: EditorModel
    let blocks: [FlowBlock]
    let parent: UUID?
    let branch: BlockSlot.Branch
    let status: [UUID: RunRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { k, b in
                DropGap(model: model, slot: BlockSlot(parent: parent, branch: branch, index: k))
                BlockCard(model: model, block: b, status: status)
                    .id(b.id)
            }
            if blocks.isEmpty && parent != nil {
                EmptyBranch(model: model, slot: BlockSlot(parent: parent, branch: branch, index: 0))
            } else {
                DropGap(model: model, slot: BlockSlot(parent: parent, branch: branch, index: blocks.count))
            }
        }
    }
}

/// Between two steps: where a dragged one goes (a line shows while it's over it).
struct DropGap: View {
    @ObservedObject var model: EditorModel
    let slot: BlockSlot
    @State private var targeted = false

    var body: some View {
        ZStack {
            Color.clear
            if targeted {
                Capsule().fill(Color.accentColor).frame(height: 4)
            }
        }
        .frame(height: targeted ? 22 : 10)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            items.first.map { model.drop($0, at: slot) } ?? false
        } isTargeted: { t in withAnimation(.easeOut(duration: 0.1)) { targeted = t } }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

/// Inside an If or a Repeat with no steps yet.
struct EmptyBranch: View {
    @ObservedObject var model: EditorModel
    let slot: BlockSlot
    @State private var targeted = false

    var body: some View {
        let chosen = model.insertionSlot == slot && model.selected == nil
        Text(targeted ? "Drop it here" : chosen ? "The next action you click goes here" : "Drag steps here, or click here and then an action")
            .font(.callout)
            .foregroundStyle(chosen ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(targeted || chosen ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                model.selected = nil
                model.insertionSlot = slot
            }
            .dropDestination(for: String.self) { items, _ in
                items.first.map { model.drop($0, at: slot) } ?? false
            } isTargeted: { targeted = $0 }
    }
}

/// One step: its title (drag it to move the step), its settings, the steps inside it (If,
/// Repeat), and how it went in the last run.
struct BlockCard: View {
    @ObservedObject var model: EditorModel
    let block: FlowBlock
    let status: [UUID: RunRecord]
    @State private var hover = false

    var body: some View {
        let selected = model.selected == block.id
        let problem = model.problemBlock == block.id
        let step = status[block.id]
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            // A click on its own title or settings picks it (one on a step inside it picks that one).
            VStack(alignment: .leading, spacing: 8) {
                header(step)
                BlockFields(model: model, block: block)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                model.selected = block.id
                model.insertionSlot = nil
            })
            if block.type.isContainer { inside }
            if problem, case let .problem(e) = model.check {
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.message).foregroundStyle(.red)
                    if let fix = e.fix { Text("→ \(fix)").foregroundStyle(.secondary) }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(shape.fill(block.type == .comment ? Color.yellow.opacity(0.13) : Color(nsColor: .textBackgroundColor)))
        .overlay {
            if step?.state == .running {
                RunningBorder(shape: shape)
            } else {
                shape.strokeBorder(problem ? Color.red : selected ? Color.accentColor : Color.primary.opacity(hover ? 0.18 : 0.08),
                                   lineWidth: problem || selected ? 2 : 1)
            }
        }
        .shadow(color: .black.opacity(hover ? 0.10 : 0.05), radius: hover ? 4 : 2, y: 1)
        .onHover { hover = $0 }
        .dropDestination(for: String.self) { items, _ in
            // Dropped on a step: it goes after it.
            guard let first = items.first, let s = model.doc.slot(of: block.id) else { return false }
            return model.drop(first, at: BlockSlot(parent: s.parent, branch: s.branch, index: s.index + 1))
        }
        .contextMenu { menu }
    }

    private func header(_ step: RunRecord?) -> some View {
        HStack(spacing: 8) {
            BlockStyle.tile(block.type, symbol: epaCommand?.symbol)
            Text(block.type == .epa ? block.headline : block.type.info.title)
                .font(.headline)
            Spacer(minLength: 6)
            if let step {
                Button { Windows.showRuns(step.id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: Theme.symbol(step.state)).foregroundStyle(Theme.color(step.state))
                        if step.state == .running {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(RunRecord.duration(ctx.date.timeIntervalSince(step.started))).monospacedDigit()
                            }
                        } else if let secs = step.seconds {
                            Text(RunRecord.duration(secs)).monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("In the last run: \(step.state.title.lowercased()). Click to see what it printed.")
            }
            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Duplicate, move, remove this step")
        }
        .contentShape(Rectangle())
        .draggable("block:\(block.id.uuidString)") {
            HStack(spacing: 6) {
                BlockStyle.tile(block.type, size: 20)
                Text(block.headline).font(.callout.weight(.semibold))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
        .help("Drag the title to move this step")
    }

    /// The EPA command an EPA step runs (for its title and symbol).
    private var epaCommand: EPA.Command? { block.type == .epa ? EPA.command(named: block.script, args: block.args) : nil }

    @ViewBuilder
    private var menu: some View {
        Button("Duplicate") { model.duplicate(block.id) }
        Button("Move Up") { model.nudge(block.id, by: -1) }
        Button("Move Down") { model.nudge(block.id, by: 1) }
        Button("Ask to Continue Before This") { model.askBefore(block.id) }
        Divider()
        Button("Remove", role: .destructive) { model.remove(block.id) }
    }

    /// The steps inside an If (and Otherwise) or a Repeat, indented, with a rail of its color.
    @ViewBuilder
    private var inside: some View {
        let rail = BlockStyle.color(block.type).opacity(0.5)
        VStack(alignment: .leading, spacing: 4) {
            BlockList(model: model, blocks: block.children, parent: block.id, branch: .body, status: status)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Capsule().fill(rail).frame(width: 3) }
            if block.type == .ifThen {
                if block.hasOtherwise || !block.otherwise.isEmpty {
                    HStack {
                        Text("Otherwise").font(.headline).foregroundStyle(BlockStyle.color(block.type))
                        Spacer()
                        Button {
                            model.edit { d in
                                d.update(block.id) {
                                    $0.otherwise = []
                                    $0.hasOtherwise = false
                                }
                            }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Take away Otherwise (and the steps in it)")
                    }
                    BlockList(model: model, blocks: block.otherwise, parent: block.id, branch: .otherwise, status: status)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) { Capsule().fill(rail).frame(width: 3) }
                } else {
                    Button {
                        model.edit { $0.update(block.id) { $0.hasOtherwise = true } }
                    } label: { Label("Add Otherwise", systemImage: "plus") }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .help("Steps to do when it isn't true")
                }
            }
            Text(block.type == .ifThen ? "End If" : "End Repeat")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// A step's settings, written as a sentence where it can be ("Run hello with …").
struct BlockFields: View {
    @ObservedObject var model: EditorModel
    let block: FlowBlock

    private var id: UUID { block.id }
    private var vars: [FlowVariable] { model.doc.variables(before: block.id) }

    var body: some View {
        switch block.type {
        case .runScript: runScript
        case .epa: epa
        case .shell:
            TemplateField(model: model, id: id, key: \.text, placeholder: "a line of shell, such as ls -la", vars: vars, mono: true)
            OutputName(model: model, block: block, what: "What it printed is called")
        case .show:
            TemplateField(model: model, id: id, key: \.text, placeholder: "Text, or a value from an earlier step", vars: vars, multiline: true)
        case .notify:
            TemplateField(model: model, id: id, key: \.text, placeholder: "What the notification says", vars: vars)
        case .confirm:
            TemplateField(model: model, id: id, key: \.text, placeholder: "The question, such as Delete the old backups?", vars: vars)
            Note("The flow stops here and asks. Continue goes on; Stop ends the flow.")
        case .ask:
            TemplateField(model: model, id: id, key: \.text, placeholder: "The question", vars: vars)
            OutputName(model: model, block: block, what: "The answer is called")
        case .askYesNo:
            TemplateField(model: model, id: id, key: \.text, placeholder: "A yes-or-no question", vars: vars)
            OutputName(model: model, block: block, what: "The answer (true or false) is called")
        case .choose:
            TemplateField(model: model, id: id, key: \.text, placeholder: "The question", vars: vars)
            LabeledRow("Choices") { ArgumentChips(model: model, id: id, key: \.args, vars: vars, addTitle: "Add a Choice") }
            OutputName(model: model, block: block, what: "The one picked is called")
        case .text:
            TemplateField(model: model, id: id, key: \.text, placeholder: "Text, with values from earlier steps in it", vars: vars, multiline: true)
            OutputName(model: model, block: block, what: "It's called")
        case .readFile:
            LabeledRow("File") { TemplateField(model: model, id: id, key: \.text, placeholder: "~/Desktop/notes.txt", vars: vars, mono: true) }
            OutputName(model: model, block: block, what: "What's in it is called")
        case .writeFile:
            LabeledRow("Save") { TemplateField(model: model, id: id, key: \.text, placeholder: "the text to save", vars: vars) }
            LabeledRow("To") { TemplateField(model: model, id: id, key: \.input, placeholder: "~/Desktop/output.txt", vars: vars, mono: true) }
            Note("It replaces what's in the file, if there's one there.")
        case .wait:
            HStack(spacing: 6) {
                Text("Wait")
                NumberField(model: model, id: id, key: \.number, vars: vars)
                Text("seconds")
            }
        case .stop:
            TemplateField(model: model, id: id, key: \.text, placeholder: "Why it stopped", vars: vars)
            Note("The flow ends here as failed, with this message.")
        case .comment:
            TextField("A note", text: model.binding(id, \.text, ""), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...12)
        case .code:
            CodeField(model: model, id: id)
        case .ifThen:
            ConditionRow(model: model, block: block, vars: vars)
        case .repeatEach:
            HStack(spacing: 6) {
                Text("For each")
                Picker("", selection: model.binding(id, \.eachLine, true)) {
                    Text("line").tag(true)
                    Text("item").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Text("of")
                ValuePicker(model: model, id: id, key: \.subject, vars: vars.filter { $0.kind == .text || $0.kind == .list || $0.kind == .other })
            }
            LoopName(model: model, block: block)
        case .repeatCount:
            HStack(spacing: 6) {
                Text("Repeat")
                NumberField(model: model, id: id, key: \.number, vars: vars)
                Text("times")
            }
            LoopName(model: model, block: block)
        }
    }

    @ViewBuilder
    private var runScript: some View {
        HStack(spacing: 6) {
            Text("Run")
            ScriptPicker(model: model, id: id, current: block.script)
        }
        LabeledRow("With") { ArgumentChips(model: model, id: id, key: \.args, vars: vars, addTitle: "Add an Argument") }
        if !block.input.isEmpty {
            LabeledRow("Input") {
                HStack {
                    TemplateField(model: model, id: id, key: \.input, placeholder: "text handed to it as its input (stdin)", vars: vars)
                    Button { model.edit { $0.update(id) { $0.input = "" } } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("No input")
                }
            }
        }
        HStack(spacing: 10) {
            Picker("If it fails:", selection: model.binding(id, \.keepGoing, false)) {
                Text("Stop the flow").tag(false)
                Text("Keep going").tag(true)
            }
            .fixedSize()
            .help("Keep going: the flow carries on, and the step's result says whether it worked (.ok), its output (.out), errors (.err) and exit code (.code)")
            if block.input.isEmpty {
                Menu {
                    let last = vars.last { $0.kind == .text }
                    if let last {
                        Button("What \(last.name) holds") { model.edit { $0.update(id) { $0.input = "{\(last.name)}" } } }
                    }
                    Button("Text…") { model.edit { $0.update(id) { $0.input = "text" } } }
                } label: { Label("Give It Input", systemImage: "arrow.right.doc.on.clipboard") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Hand it text as its input (stdin), as a | does in a terminal")
            }
        }
        OutputName(model: model, block: block, what: block.keepGoing ? "Its result is called" : "What it printed is called")
    }
}

extension BlockFields {
    /// An EPA step: which command, its words, what happens when it fails, what its output is called.
    @ViewBuilder
    var epa: some View {
        let command = EPA.command(named: block.script, args: block.args)
        HStack(spacing: 6) {
            Text("EPA")
            EPACommandPicker(model: model, id: id, current: block.script, args: block.args)
        }
        LabeledRow("With") { ArgumentChips(model: model, id: id, key: \.args, vars: vars, addTitle: "Add a Word") }
        if let command {
            Note(command.summary + (command.changes ? " EPA shows its plan and asks before it changes anything." : ""))
        }
        HStack(spacing: 10) {
            Picker("If it fails:", selection: model.binding(id, \.keepGoing, false)) {
                Text("Stop the flow").tag(false)
                Text("Keep going").tag(true)
            }
            .fixedSize()
            .help("Keep going: the flow carries on, and the step's result says whether it worked (.ok), what EPA showed (.out), and what failed with its next step (.err)")
            Text((["epa", block.script] + block.args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }).joined(separator: " "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help("What it runs, as you'd type it in a terminal (in your scripts folder, where EPA's keys are)")
        }
        OutputName(model: model, block: block, what: block.keepGoing ? "Its result is called" : "What it showed is called")
    }
}

/// Which EPA command an EPA step runs, picked from what EPA does.
struct EPACommandPicker: View {
    @ObservedObject var model: EditorModel
    let id: UUID
    let current: String
    let args: [String]

    var body: some View {
        let known = EPA.commandNames.contains(current)
        HStack(spacing: 6) {
            Menu {
                Section("Changes something (EPA asks first)") {
                    ForEach(EPA.commands.filter(\.changes)) { c in Button(c.title) { pick(c) } }
                }
                Section("Read-only") {
                    ForEach(EPA.commands.filter { !$0.changes }) { c in Button(c.title) { pick(c) } }
                }
            } label: {
                Text(EPA.command(named: current, args: args)?.title ?? (current.isEmpty ? "Choose What EPA Does" : current))
                    .font(.body.weight(.semibold))
            }
            .fixedSize()
            .help("Picking one puts in its example words, ready to change (⌘Z goes back)")
            if !current.isEmpty && !known {
                Label("Not an EPA command", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func pick(_ c: EPA.Command) {
        model.edit { d in
            d.update(id) {
                $0.script = c.name
                $0.args = c.args
            }
        }
    }
}

/// A short line of help under a step's settings.
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A label, then a field.
struct LabeledRow<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder _ content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            content
        }
    }
}

/// A text field whose text can carry values from earlier steps ({name}), with ⊕ to put one in.
struct TemplateField: View {
    @ObservedObject var model: EditorModel
    let id: UUID
    let key: WritableKeyPath<FlowBlock, String>
    let placeholder: String
    let vars: [FlowVariable]
    var multiline = false
    var mono = false

    var body: some View {
        let text = model.binding(id, key, "")
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Group {
                if multiline {
                    TextField(placeholder, text: text, axis: .vertical).lineLimit(1...8)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(mono ? .body.monospaced() : .body)
            ValueMenu(vars: vars) { text.wrappedValue += $0 }
        }
    }
}

/// ⊕: the values from earlier steps (a script's result: what it printed, its errors…).
struct ValueMenu: View {
    let vars: [FlowVariable]
    let pick: (String) -> Void

    var body: some View {
        Menu {
            let shown = vars.filter { $0.name != "args" }
            if shown.isEmpty {
                Text("No values yet: a step's output can be used in the steps after it")
            }
            ForEach(shown, id: \.name) { v in
                if v.kind == .result {
                    Menu("\(v.name)  ·  \(v.source)") {
                        Button("What it printed") { pick("{\(v.name).out}") }
                        Button("Its errors") { pick("{\(v.name).err}") }
                        Button("Its exit code") { pick("{\(v.name).code}") }
                        Button("Whether it worked") { pick("{\(v.name).ok}") }
                    }
                } else {
                    Button("\(v.name)  ·  \(v.source)") { pick("{\(v.name)}") }
                }
            }
            Divider()
            Button("The flow's arguments") { pick("{args}") }
            Button("The date and time now") { pick("{now ()}") }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Put in a value from an earlier step (it's written {name}; the text around it stays as it is)")
    }
}

/// A list of short texts (a script's arguments, the choices), each a chip, with one to add.
struct ArgumentChips: View {
    @ObservedObject var model: EditorModel
    let id: UUID
    let key: WritableKeyPath<FlowBlock, [String]>
    let vars: [FlowVariable]
    let addTitle: String

    var body: some View {
        let list = model.binding(id, key, [])
        WrapLayout(spacing: 6) {
            ForEach(list.wrappedValue.indices, id: \.self) { k in
                HStack(spacing: 2) {
                    TextField("", text: Binding(get: { k < list.wrappedValue.count ? list.wrappedValue[k] : "" },
                                                set: { v in if k < list.wrappedValue.count { list.wrappedValue[k] = v } }))
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                        .frame(width: Self.width(k < list.wrappedValue.count ? list.wrappedValue[k] : ""))
                    Button {
                        model.edit { $0.update(id) { b in if k < b[keyPath: key].count { b[keyPath: key].remove(at: k) } } }
                    } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
            Menu {
                Button("Text") { model.edit { $0.update(id) { $0[keyPath: key].append("") } } }
                let shown = vars.filter { $0.name != "args" }
                if !shown.isEmpty { Divider() }
                ForEach(shown, id: \.name) { v in
                    Button(v.kind == .result ? "\(v.name) (what it printed)" : v.name) {
                        let hole = v.kind == .result ? "{\(v.name).out}" : "{\(v.name)}"
                        model.edit { $0.update(id) { $0[keyPath: key].append(hole) } }
                    }
                }
            } label: {
                Label(list.wrappedValue.isEmpty ? addTitle : "Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    static func width(_ s: String) -> CGFloat { min(260, max(48, CGFloat(s.count) * 8 + 16)) }
}

/// A number, or a value from an earlier step.
struct NumberField: View {
    @ObservedObject var model: EditorModel
    let id: UUID
    let key: WritableKeyPath<FlowBlock, String>
    let vars: [FlowVariable]

    var body: some View {
        let text = model.binding(id, key, "")
        HStack(spacing: 2) {
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .frame(width: max(54, ArgumentChips.width(text.wrappedValue)))
            if let n = Int(text.wrappedValue.trimmingCharacters(in: .whitespaces)) {
                Stepper("", onIncrement: { text.wrappedValue = String(n + 1) }, onDecrement: { text.wrappedValue = String(max(0, n - 1)) })
                    .labelsHidden()
            }
            let numbers = vars.filter { $0.kind == .number || $0.kind == .other || $0.kind == .text }.filter { $0.name != "args" }
            if !numbers.isEmpty {
                Menu {
                    ForEach(numbers, id: \.name) { v in
                        Button(v.name) { text.wrappedValue = v.kind == .text ? "{int \(v.name)}" : "{\(v.name)}" }
                    }
                } label: { Image(systemName: "plus.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Use a number from an earlier step")
            }
        }
    }
}

/// Which script a Run Script runs: any in the folder (or a flow), picked from a menu.
struct ScriptPicker: View {
    @ObservedObject var model: EditorModel
    let id: UUID
    let current: String

    var body: some View {
        let known = (model.app.scripts + model.app.flows).contains { model.runName($0) == current || $0.id == current || $0.title == current }
        HStack(spacing: 6) {
            Menu {
                Section("Scripts") {
                    ForEach(model.app.scripts) { s in
                        Button("\(s.title)  ·  \(s.language.title)") { pick(s) }
                    }
                }
                if !model.app.flows.isEmpty {
                    Section("Flows") {
                        ForEach(model.app.flows.filter { $0.id != model.item.id }) { f in
                            Button(f.title) { pick(f) }
                        }
                    }
                }
            } label: {
                Text(current.isEmpty ? "Choose a Script" : current)
                    .font(.body.weight(.semibold))
            }
            .fixedSize()
            if !current.isEmpty && !known {
                Label("Not in your scripts folder", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func pick(_ s: ScriptItem) {
        let name = model.runName(s)
        guard name != current else { return }
        let oldDefault = FlowDocument.variableName(for: current)
        model.edit { $0.update(id) { $0.script = name } }
        // Its output was named after the old script: it's named after the new one.
        if let b = model.doc.block(id), b.name.hasPrefix(oldDefault) || b.name == "output" {
            model.renameOutput(id, to: FlowDocument.variableName(for: name))
        }
    }
}

/// What a step's output is called (renamed where it's used, too, when changed).
struct OutputName: View {
    @ObservedObject var model: EditorModel
    let block: FlowBlock
    let what: String
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).font(.caption)
            Text(what).foregroundStyle(.secondary).font(.callout)
            TextField("nothing (not kept)", text: $typed)
                .textFieldStyle(.plain)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(BlockStyle.color(block.type))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(BlockStyle.color(block.type).opacity(0.12)))
                .frame(width: ArgumentChips.width(typed) + 10)
                .focused($focused)
                .onSubmit { model.renameOutput(block.id, to: typed) }
                .onChange(of: focused) { _, f in if !f { model.renameOutput(block.id, to: typed) } }
                .help("Steps after this one use it by this name: ⊕ beside a field puts it in")
        }
        .onAppear { typed = block.name }
        .onChange(of: block.name) { _, n in if !focused { typed = n } }
    }
}

/// What a Repeat's item (or count) is called.
struct LoopName: View {
    @ObservedObject var model: EditorModel
    let block: FlowBlock

    var body: some View {
        OutputName(model: model, block: block, what: block.type == .repeatCount ? "Each time, the count is called" : "Each time, the \(block.eachLine ? "line" : "item") is called")
    }
}

/// A value from an earlier step, picked from a menu, or typed as Flow.
struct ValuePicker: View {
    @ObservedObject var model: EditorModel
    let id: UUID
    let key: WritableKeyPath<FlowBlock, String>
    let vars: [FlowVariable]
    @State private var typing = false

    var body: some View {
        let value = model.binding(id, key, "")
        let isVar = vars.contains { $0.name == value.wrappedValue }
        HStack(spacing: 4) {
            if typing || (!isVar && !value.wrappedValue.isEmpty) {
                TextField("Flow, such as lines notes", text: value)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(minWidth: 120)
            }
            Menu {
                ForEach(vars, id: \.name) { v in
                    Button("\(v.name)  ·  \(v.source)") {
                        typing = false
                        value.wrappedValue = v.name
                    }
                }
                Divider()
                Button("Type Flow…") { typing = true }
            } label: {
                Text(isVar ? value.wrappedValue : value.wrappedValue.isEmpty ? "Choose a Value" : "Other")
                    .font(.body.monospaced().weight(.semibold))
            }
            .fixedSize()
        }
    }
}

/// An If's test: "If [value] [is greater than] [85]".
struct ConditionRow: View {
    @ObservedObject var model: EditorModel
    let block: FlowBlock
    let vars: [FlowVariable]

    private var c: Condition { block.condition }

    var body: some View {
        let kind = vars.last { $0.name == c.subject.trimmingCharacters(in: .whitespaces) }?.kind ?? .other
        HStack(spacing: 6) {
            Text("If")
            if c.test == .code {
                TextField("Flow that's true or false, such as n > 3 && ok", text: model.binding(block.id, \.condition.subject, ""))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            } else {
                if c.test.usesSubject {
                    Menu {
                        ForEach(vars.filter { $0.name != "args" }, id: \.name) { v in
                            Button("\(v.name)  ·  \(v.source)") { setSubject(v) }
                        }
                    } label: {
                        Text(c.subject.isEmpty ? "Choose a Value" : c.subject).font(.body.monospaced().weight(.semibold))
                    }
                    .fixedSize()
                }
                Menu {
                    ForEach(Condition.Test.offered(for: kind), id: \.self) { t in
                        Button(t.title) { setTest(t, kind) }
                    }
                    Divider()
                    ForEach([Condition.Test.answeredYes, .exists, .notExists, .code], id: \.self) { t in
                        Button(t == .code ? "Write the Test in Flow…" : t.title) { setTest(t, kind) }
                    }
                } label: {
                    Text(c.test.title)
                }
                .fixedSize()
                if c.test.usesValue {
                    if c.test.numeric || c.bare {
                        NumberField(model: model, id: block.id, key: \.condition.value, vars: vars)
                    } else {
                        TemplateField(model: model, id: block.id, key: \.condition.value,
                                      placeholder: c.test == .answeredYes ? "the question" : c.test == .exists || c.test == .notExists ? "~/path/to/file" : "text",
                                      vars: vars)
                    }
                }
            }
        }
        if c.test == .code {
            Button("Use the Menus Instead") { setTest(.equals, kind) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func setSubject(_ v: FlowVariable) {
        let offered = Condition.Test.offered(for: v.kind)
        model.edit { d in
            d.update(block.id) { b in
                b.condition.subject = v.name
                if !offered.contains(b.condition.test) { b.condition.test = offered[0] }
                Self.fit(&b.condition, v.kind)
            }
        }
    }

    private func setTest(_ t: Condition.Test, _ kind: ValueKind) {
        model.edit { d in
            d.update(block.id) { b in
                if t == .code && b.condition.test != .code {
                    // What it was, as Flow, to start from.
                    b.condition.subject = b.condition.subject.isEmpty ? "true" : b.condition.subject
                }
                b.condition.test = t
                if t == .answeredYes && b.condition.value.isEmpty { b.condition.value = "Go ahead?" }
                Self.fit(&b.condition, kind)
            }
        }
    }

    /// Numbers compare as numbers: text read as one, a number written as it is.
    static func fit(_ c: inout Condition, _ kind: ValueKind) {
        c.asNumber = c.test.numeric && kind == .text
        c.bare = c.test.numeric || ((c.test == .equals || c.test == .notEquals) && kind == .number)
        if c.bare && c.value.isEmpty { c.value = "0" }
    }
}

/// Flow typed as it is (a function of your own, a pipeline): monospaced, several lines.
struct CodeField: View {
    @ObservedObject var model: EditorModel
    let id: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Flow code", text: model.binding(id, \.text, ""), axis: .vertical)
                .font(.system(size: 12.5, design: .monospaced))
                .textFieldStyle(.plain)
                .lineLimit(1...30)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            HStack(spacing: 10) {
                Note("Any Flow: the Flow guide has every function.")
                Button("Open the Guide") { Windows.showGuide() }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

/// On the right: your scripts and every kind of step. Click one to add it (after the step
/// picked), or drag it where it goes.
struct BlockLibrary: View {
    @ObservedObject var model: EditorModel
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search scripts and actions", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let scripts = model.app.scripts.filter { matches($0.title + " " + ($0.summary ?? "")) }
                    if search.isEmpty || !scripts.isEmpty {
                        section("Your Scripts") {
                            if model.app.scripts.isEmpty {
                                Note("No scripts in your folder yet: add one on the Scripts grid.")
                            }
                            ForEach(scripts) { s in
                                LibraryRow(type: .runScript, title: s.title, subtitle: s.summary ?? s.language.title, badge: s.language.badge)
                                    .onTapGesture { model.add(.runScript, script: model.runName(s)) }
                                    .draggable("script:\(model.runName(s))") { LibraryRow(type: .runScript, title: s.title, subtitle: nil, badge: nil) }
                            }
                        }
                    }
                    let flows = model.app.flows.filter { $0.id != model.item.id && matches($0.title + " " + ($0.summary ?? "")) }
                    if !flows.isEmpty {
                        section("Your Flows") {
                            ForEach(flows) { f in
                                LibraryRow(type: .runScript, title: f.title, subtitle: f.summary ?? "A flow", badge: "flow")
                                    .onTapGesture { model.add(.runScript, script: model.runName(f)) }
                                    .draggable("script:\(model.runName(f))") { LibraryRow(type: .runScript, title: f.title, subtitle: nil, badge: nil) }
                            }
                        }
                    }
                    let epaCommands = EPA.commands.filter { matches("EPA " + $0.title + " " + $0.summary) }
                    if !epaCommands.isEmpty {
                        section("EPA") {
                            ForEach(epaCommands) { c in
                                LibraryRow(type: .epa, title: c.title, subtitle: c.summary, badge: c.changes ? nil : "read-only", symbol: c.symbol)
                                    .onTapGesture { model.add(.epa, script: c.title) }
                                    .draggable("epa:\(c.title)") { LibraryRow(type: .epa, title: c.title, subtitle: nil, badge: nil, symbol: c.symbol) }
                            }
                        }
                    }
                    ForEach(BlockGroup.allCases, id: \.self) { group in
                        let types = group.types.filter { t in t != .runScript && t != .epa && matches(t.info.title + " " + t.info.summary) }
                        if !types.isEmpty {
                            section(group.rawValue) {
                                ForEach(types, id: \.self) { t in
                                    LibraryRow(type: t, title: t.info.title, subtitle: t.info.summary, badge: nil)
                                        .onTapGesture { model.add(t) }
                                        .draggable("new:\(t.rawValue)") { LibraryRow(type: t, title: t.info.title, subtitle: nil, badge: nil) }
                                }
                            }
                        }
                    }
                    Button { Windows.showGuide() } label: { Label("The Flow Guide", systemImage: "book") }
                        .buttonStyle(.link)
                }
                .padding(12)
            }
            Divider()
            Text(model.selected != nil ? "A click adds it after the step picked." : "A click adds it at the end (or where you clicked inside an If or a Repeat).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func matches(_ s: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || s.lowercased().contains(q)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// An entry in the library.
struct LibraryRow: View {
    let type: BlockType
    let title: String
    let subtitle: String?
    let badge: String?
    /// Its own symbol (an EPA command's), instead of its kind's.
    var symbol: String? = nil
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            BlockStyle.tile(type, size: 24, symbol: symbol)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    if let badge {
                        Text(badge).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help((subtitle ?? title) + "\n\nClick to add it, or drag it into place.")
    }
}

/// Lays its views out in rows, starting a new row when one is full.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
