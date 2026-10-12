import AppKit
import RunCore
import SwiftUI

/// Editing a script or a flow: saved as you type (and back to how it was opened with Revert),
/// renamed from its name at the top, run with Save & Run (its output shows underneath). A flow's
/// types are worked out as you type, beside it.
@MainActor
final class EditorModel: ObservableObject {
    enum SaveState: Equatable {
        case saved, unsaved, failed(String)
    }

    enum CheckState {
        case none
        case ok([FlowBinding])
        case problem(FlowError)
    }

    @Published private(set) var item: ScriptItem
    let kind: GridKind
    let app: AppModel
    @Published var text: String {
        didSet {
            guard text != oldValue else { return }
            saveState = .unsaved
            scheduleSave()
            scheduleCheck()
        }
    }
    @Published var name: String
    @Published private(set) var saveState: SaveState = .saved
    @Published private(set) var check: CheckState = .none
    @Published var renameProblem: String?
    /// The text as it was opened (Revert goes back to it).
    private(set) var original: String
    let handle = TextHandle()
    private var saveTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?

    init(item: ScriptItem, kind: GridKind, app: AppModel) {
        self.item = item
        self.kind = kind
        self.app = app
        let contents = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
        text = contents
        original = contents
        name = item.title
        runCheck()
    }

    var isFlow: Bool { kind == .composer }

    /// What it's written in, told from what's typed now.
    var language: ScriptLanguage {
        ScriptLanguage.detect(fileName: item.url.lastPathComponent, contents: text,
                              executableBit: FileManager.default.isExecutableFile(atPath: item.url.path))
    }

    var languageNote: String {
        guard !isFlow else { return "Flow" }
        let lang = language
        if text.hasPrefix("#!") { return "\(lang.title) · from its first line" }
        if lang == .unknown { return "Language unknown: add a #! line or an extension" }
        return "\(lang.title) · from its name"
    }

    var arguments: String {
        get { app.settings(kind).arguments[item.id] ?? "" }
        set {
            let id = item.id
            app.update(kind) { s in s.arguments[id] = newValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : newValue }
            objectWillChange.send()
        }
    }

    // MARK: saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes it, keeping the file's permissions (an executable stays executable).
    func save() {
        saveTask?.cancel()
        let url = item.url
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path) }
            saveState = .saved
            app.reload()
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func revert() {
        text = original
        save()
    }

    /// Renames the file to what's typed in the name field (its extension stays, unless one is typed).
    func commitRename() {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !typed.isEmpty else {
            name = item.title
            return
        }
        let ext = item.url.pathExtension
        let fileName = (typed as NSString).pathExtension.isEmpty && !ext.isEmpty ? "\(typed).\(ext)" : typed
        guard fileName != item.id else {
            renameProblem = nil
            return
        }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: target.path) {
            renameProblem = "There's already a \(fileName) here: pick another name."
            return
        }
        save()
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            let old = item.id
            item.url = target
            name = item.title
            renameProblem = nil
            app.renamed(kind, from: old, to: item.id)
            app.reload()
        } catch {
            renameProblem = "Couldn't rename it: \(error.localizedDescription)"
        }
    }

    /// Saves, then runs it (its output shows under the editor).
    func saveAndRun() {
        commitRename()
        save()
        var current = item
        current.language = language
        GridActions(app: app, kind: kind).run(current)
    }

    // MARK: checking a flow

    private func scheduleCheck() {
        guard isFlow else { return }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.runCheck()
        }
    }

    func runCheck() {
        guard isFlow else { return }
        let names = app.scripts.map(\.id) + app.flows.map(\.id)
        do {
            check = .ok(try Flow.check(text, scripts: names).bindings)
        } catch let e as FlowError {
            check = .problem(e)
        } catch {
            check = .none
        }
    }
}

/// The text view's handle, for jumping to a line and putting text where the cursor is.
@MainActor
final class TextHandle {
    weak var textView: NSTextView?

    func goTo(line: Int) {
        guard let tv = textView else { return }
        let s = tv.string as NSString
        var start = 0
        var current = 1
        while current < line && start < s.length {
            let r = s.lineRange(for: NSRange(location: start, length: 0))
            start = NSMaxRange(r)
            current += 1
        }
        let range = s.lineRange(for: NSRange(location: min(start, s.length), length: 0))
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
    }

    func insert(_ snippet: String) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        tv.insertText(snippet, replacementRange: tv.selectedRange())
    }
}

/// A plain-text code editor: monospaced, with the Mac's "smart" quotes, dashes and corrections
/// off (they'd break code), and undo.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let handle: TextHandle

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 10, height: 12)
        tv.string = text
        tv.delegate = context.coordinator
        handle.textView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        let selection = tv.selectedRanges
        tv.string = text
        tv.selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= (text as NSString).length }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var runs: RunStore
    let windowID: String
    @State private var trashing = false
    @State private var showOutput = true
    @FocusState private var nameFocused: Bool

    init(model: EditorModel, windowID: String) {
        self.model = model
        runs = model.app.runs
        self.windowID = windowID
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 34)
                .padding(.bottom, 10)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    CodeEditor(text: $model.text, handle: model.handle)
                    if showOutput, let run = runs.latest(file: model.item.id, kind: model.kind) {
                        Divider()
                        OutputPanel(run: run, runs: runs)
                            .frame(height: 200)
                    }
                }
                if model.isFlow {
                    Divider()
                    FlowSidebar(model: model)
                        .frame(width: 320)
                }
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear {
            // A new one: its name is the first thing to type.
            if model.item.title.hasPrefix("untitled") { nameFocused = true }
        }
        .onDisappear { model.save() }
        .confirmationDialog("Move \(model.item.id) to the Trash?", isPresented: $trashing) {
            Button("Move to Trash", role: .destructive) {
                GridActions(app: model.app, kind: model.kind).trash(model.item)
                Windows.forget(windowID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes to the Trash, so you can get it back from there (Put Back).")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    TextField("Name", text: $model.name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .focused($nameFocused)
                        .onSubmit { model.commitRename() }
                        .onChange(of: nameFocused) { _, focused in if !focused { model.commitRename() } }
                        .frame(maxWidth: 360)
                        .help("Its name: type to rename the file (Return)")
                    if !model.item.url.pathExtension.isEmpty {
                        Text(".\(model.item.url.pathExtension)").font(.title2).foregroundStyle(.secondary)
                    }
                }
                if let problem = model.renameProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else {
                    Text(model.languageNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            saveBadge
            Button("Revert") { model.revert() }
                .disabled(model.text == model.original)
                .help("Back to how it was when this window opened")
            Button { model.saveAndRun() } label: { Label("Save & Run", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r")
                .help("Save it and run it (⌘R); the output shows underneath")
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var saveBadge: some View {
        switch model.saveState {
        case .saved:
            Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .unsaved:
            Label("Saving…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case let .failed(message):
            Label("Not saved: \(message)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Arguments when its cell is clicked:").foregroundStyle(.secondary)
            TextField("none", text: Binding(get: { model.arguments }, set: { model.arguments = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono)
                .frame(maxWidth: 320)
            Toggle("Output", isOn: $showOutput)
                .toggleStyle(.checkbox)
                .help("Show the last run's output under the editor")
            Spacer()
            Button("Save") { model.save() }
                .keyboardShortcut("s")
            Button("Open in \(GridActions.editorName)") {
                model.save()
                GridActions(app: model.app, kind: model.kind).openInEditor(model.item)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.item.url]) }
            Button("Move to Trash…", role: .destructive) { trashing = true }
                .foregroundStyle(.red)
        }
    }
}

/// Beside a flow: whether it checks out and the type of everything it defines (or what's wrong
/// and how to fix it), then the scripts it can run and the functions it can use (a click puts
/// one in).
struct FlowSidebar: View {
    @ObservedObject var model: EditorModel
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                checkSection
                section("Your scripts", note: "A click puts in a run of it.") {
                    if model.app.scripts.isEmpty {
                        Text("No scripts in your folder yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.app.scripts) { s in
                        Button {
                            model.handle.insert("run \"\(s.title)\" []")
                        } label: {
                            HStack {
                                Text(s.language.badge).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                                Text(s.title).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(s.summary ?? s.id)
                    }
                }
                section("Functions", note: "A click puts it in. The guide has them all, with examples.") {
                    TextField("Find a function", text: $search)
                        .textFieldStyle(.roundedBorder)
                    ForEach(filtered, id: \.name) { b in
                        Button {
                            model.handle.insert(b.name + " ")
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(b.name).font(.callout.monospaced().weight(.semibold))
                                Text(b.signature).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(b.summary + "\n\nFor example:\n" + b.example)
                    }
                    Button("Open the Flow Guide") { Windows.showGuide() }
                        .padding(.top, 4)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filtered: [Builtin] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Builtin.all }
        return Builtin.all.filter { $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
    }

    @ViewBuilder
    private var checkSection: some View {
        switch model.check {
        case .none:
            EmptyView()
        case let .ok(bindings):
            section("✅ Checks out", note: bindings.isEmpty ? "Every type is worked out as you type." : "The type worked out for each name it defines:") {
                ForEach(bindings, id: \.name) { b in
                    Button { model.handle.goTo(line: b.line) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(b.name).font(.callout.monospaced().weight(.semibold))
                            Text(": \(b.type)").font(.callout.monospaced()).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Line \(b.line): click to go there")
                }
            }
        case let .problem(e):
            VStack(alignment: .leading, spacing: 8) {
                Label(e.stage == .syntax ? "Can't read this yet" : "This won't run yet", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(e.message).fixedSize(horizontal: false, vertical: true)
                if let fix = e.fix {
                    Text("→ \(fix)").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let pos = e.pos {
                    Button("Go to line \(pos.line)") { model.handle.goTo(line: pos.line) }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
        }
    }

    private func section<Content: View>(_ title: String, note: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
