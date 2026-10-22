import Foundation

// The block editor's view of a flow: a list of steps, like Apple's Shortcuts, each a block with
// its settings (which script, its arguments, what its output is called…). Blocks are written as
// Flow and read back from it, so the two editors are two views of the same file:
//
//   - A block reads back exactly as it was written (the tests walk every kind).
//   - Flow the blocks don't know (a function of your own, a long pipeline) is a Code block, kept
//     word for word. Nothing in a file is ever lost by opening it as blocks.
//   - A block that wasn't changed is written back as it was in the file (its spacing, its
//     comments, its way of saying it), so editing one block doesn't rewrite the rest.

// MARK: - What a block can be

/// The kinds of block. Each is one way of writing a step in Flow (see `BlockWriter`).
public enum BlockType: String, CaseIterable, Codable, Sendable {
    case runScript, shell, epa, show, showResult, notify, confirm, ask, askYesNo, choose, text, readFile, writeFile
    case ifThen, repeatEach, repeatCount, wait, stop, comment, code

    /// What it's called, its symbol (SF Symbols), its group in the library, and what it does.
    /// The block editor's library and its cards read this table.
    public var info: (title: String, symbol: String, group: BlockGroup, summary: String) {
        switch self {
        case .runScript: ("Run Script", "terminal", .scripts, "Runs one of your scripts, with arguments (and text as its input, if you like). Its output is kept under a name for the next steps.")
        case .shell: ("Run Shell Command", "chevron.left.forwardslash.chevron.right", .scripts, "Runs one line of shell (bash) and keeps what it printed.")
        case .epa: ("EPA", "bolt.horizontal.circle", .epa, "Runs one of EPA's commands (connect a service, secure a site, onboard someone…) and keeps what it showed. EPA asks before it changes anything.")
        case .show: ("Show in Output", "text.alignleft", .tell, "Writes text (or a value from an earlier step) into the run's output, without stopping.")
        case .showResult: ("Show Result", "text.bubble", .tell, "Shows text (or a value from an earlier step) in a window, like Shortcuts' Show Result, and waits for Done.")
        case .notify: ("Show Notification", "bell.badge", .tell, "Shows a notification on the screen.")
        case .confirm: ("Ask to Continue", "hand.raised", .ask, "Stops and asks before going on: Continue carries on, Stop ends the flow there. Put it before anything that deletes, sends or costs, and say why it's asking.")
        case .ask: ("Ask for Text", "character.cursor.ibeam", .ask, "Asks for a line of text and keeps the answer. Say why, so the person knows what the answer is for.")
        case .askYesNo: ("Ask Yes or No", "questionmark.circle", .ask, "Asks a yes-or-no question and keeps the answer (true or false). Say why, so the person knows what each answer does.")
        case .choose: ("Choose from List", "list.bullet.circle", .ask, "Asks to pick one of a list and keeps the one picked. Say why, so the person knows what the choice decides.")
        case .text: ("Text", "text.alignleft", .values, "Some text, with values from earlier steps in it, kept under a name.")
        case .readFile: ("Get File Contents", "doc.text", .values, "Reads a text file and keeps what's in it.")
        case .writeFile: ("Save to File", "square.and.arrow.down", .values, "Writes text into a file (replacing what was in it).")
        case .ifThen: ("If", "arrow.triangle.branch", .logic, "Does the steps inside it only when something is true (and others, Otherwise).")
        case .repeatEach: ("Repeat with Each", "repeat", .logic, "Does the steps inside it once for each line (or item) of a value.")
        case .repeatCount: ("Repeat", "repeat.circle", .logic, "Does the steps inside it a number of times.")
        case .wait: ("Wait", "hourglass", .logic, "Waits a number of seconds.")
        case .stop: ("Stop with an Error", "xmark.octagon", .logic, "Ends the flow here as failed, saying why.")
        case .comment: ("Comment", "text.quote", .other, "A note for whoever reads the flow. It does nothing.")
        case .code: ("Flow Code", "curlybraces", .other, "Any Flow you write yourself: a function of your own, a pipeline. The Flow guide has it all.")
        }
    }

    /// Whether it holds blocks of its own.
    public var isContainer: Bool { self == .ifThen || self == .repeatEach || self == .repeatCount }

    /// Whether its result is kept under a name.
    public var hasOutput: Bool {
        switch self {
        case .runScript, .shell, .epa, .ask, .askYesNo, .choose, .text, .readFile: true
        default: false
        }
    }
}

/// The library's groups, in the order they're listed.
public enum BlockGroup: String, CaseIterable, Sendable {
    case scripts = "Scripts"
    case epa = "EPA"
    case ask = "Ask"
    case tell = "Show"
    case values = "Text & Files"
    case logic = "Logic"
    case other = "Other"

    public var types: [BlockType] { BlockType.allCases.filter { $0.info.group == self } }
}

/// What kind of value a name holds (to offer the right tests, and to write it the right way).
public enum ValueKind: String, Sendable {
    case text, number, bool, list, result, other
}

/// An If's test: "subject test value", as Shortcuts writes it ("diskSpace is greater than 85").
public struct Condition: Equatable, Sendable {
    public enum Test: String, CaseIterable, Sendable {
        case equals, notEquals, contains, notContains, startsWith, endsWith
        case greater, less, atLeast, atMost
        case isEmpty, notEmpty, succeeded, failed, isTrue, isFalse
        case exists, notExists, answeredYes, code

        /// As shown in its menu.
        public var title: String {
            switch self {
            case .equals: "is"
            case .notEquals: "is not"
            case .contains: "contains"
            case .notContains: "does not contain"
            case .startsWith: "begins with"
            case .endsWith: "ends with"
            case .greater: "is greater than"
            case .less: "is less than"
            case .atLeast: "is at least"
            case .atMost: "is at most"
            case .isEmpty: "is empty"
            case .notEmpty: "is not empty"
            case .succeeded: "succeeded"
            case .failed: "failed"
            case .isTrue: "is true"
            case .isFalse: "is false"
            case .exists: "a file exists at"
            case .notExists: "no file exists at"
            case .answeredYes: "you answer Yes to"
            case .code: "this Flow is true"
            }
        }

        /// It looks at a value from an earlier step (the others ask, or look at a file).
        public var usesSubject: Bool { ![.exists, .notExists, .answeredYes].contains(self) }
        /// It compares the subject with a value typed in.
        public var usesValue: Bool {
            [.equals, .notEquals, .contains, .notContains, .startsWith, .endsWith, .greater, .less, .atLeast, .atMost, .exists, .notExists, .answeredYes].contains(self)
        }
        /// It compares numbers.
        public var numeric: Bool { [.greater, .less, .atLeast, .atMost].contains(self) }

        /// The tests that fit a kind of value, most likely first.
        public static func offered(for kind: ValueKind) -> [Test] {
            switch kind {
            case .text: [.equals, .notEquals, .contains, .notContains, .startsWith, .endsWith, .isEmpty, .notEmpty, .greater, .less, .atLeast, .atMost]
            case .number: [.equals, .notEquals, .greater, .less, .atLeast, .atMost]
            case .bool: [.isTrue, .isFalse]
            case .list: [.isEmpty, .notEmpty]
            case .result: [.succeeded, .failed]
            case .other: [.equals, .notEquals, .greater, .less, .isTrue, .isFalse, .isEmpty, .notEmpty]
            }
        }
    }

    /// A value from an earlier step (Flow: usually just its name). For `code`, the whole test.
    public var subject: String
    public var test: Test
    /// What it's compared with: text (with {values} in it), a number, a path, a question.
    public var value: String
    /// `value` is a number or a value written as it is (not text in quotes).
    public var bare: Bool
    /// The subject is text read as a number (`int subject > 85`).
    public var asNumber: Bool

    public init(subject: String = "", test: Test = .equals, value: String = "", bare: Bool = false, asNumber: Bool = false) {
        self.subject = subject
        self.test = test
        self.value = value
        self.bare = bare
        self.asNumber = asNumber
    }
}

/// One step of a flow, as a block. Which fields matter depends on its type (see `BlockWriter`).
/// Text fields are templates: plain text, with `{name}` (any Flow, really) for a value from an
/// earlier step, and `{{` `}}` for a brace of its own.
public struct FlowBlock: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var type: BlockType
    /// Run Script: the script, as `run` names it. EPA: the `epa` command (`connect`…).
    public var script = ""
    /// Run Script, EPA: its arguments (the words after the command). Choose from List: the choices.
    public var args: [String] = []
    /// The main text: what's shown, asked, written; the command; the comment; the code; a path to read.
    public var text = ""
    /// Run Script: text handed to it as its input (empty: none). Save to File: where.
    public var input = ""
    /// Run Script, EPA: when it fails, keep going (its result is kept, with .ok) rather than stop.
    public var keepGoing = false
    /// Ask to Continue, Ask for Text, Ask Yes or No, Choose from List: why it's asking (what the
    /// answer decides, or what happens next), shown under the question. Empty: not said.
    public var why = ""
    /// What its output is called (empty: it's thrown away). Repeat: what each item is called.
    public var name = ""
    /// If: its test.
    public var condition = Condition()
    /// Wait: seconds. Repeat: how many times.
    public var number = ""
    /// Repeat with Each: what's gone through.
    public var subject = ""
    /// Repeat with Each: each line of the subject (text), rather than each item (a list).
    public var eachLine = true
    /// If: the steps when it's true. Repeat: the steps each time.
    public var children: [FlowBlock] = []
    /// If: the steps otherwise.
    public var otherwise: [FlowBlock] = []
    public var hasOtherwise = false
    /// A blank line before it in the file.
    public var blankBefore = false
    /// As it was in the file, and the Flow it was read as: written back as it was while what it
    /// would be written as now is still that.
    var original: String?
    var canonical: String?
    /// Where it was in its block's text (lines from its block's first), when that was kept.
    var originalLines: ClosedRange<Int>?

    public init(_ type: BlockType) {
        self.type = type
    }

    /// The same block with nothing about where it came from (to compare what blocks say).
    func content() -> FlowBlock {
        var b = self
        b.id = FlowBlock.zero
        b.original = nil
        b.canonical = nil
        b.originalLines = nil
        b.blankBefore = false
        b.children = children.map { $0.content() }
        b.otherwise = otherwise.map { $0.content() }
        return b
    }

    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// A copy with new ids (its own blocks too).
    public func copied() -> FlowBlock {
        var b = self
        b.id = UUID()
        b.children = children.map { $0.copied() }
        b.otherwise = otherwise.map { $0.copied() }
        return b
    }

    /// What it's called on its card: "Run hello", "If diskSpace is greater than 85"…
    public var headline: String {
        switch type {
        case .runScript: script.isEmpty ? "Run Script" : "Run \(script)"
        case .epa: EPA.command(named: script, args: args).map { "EPA: \($0.title)" } ?? "EPA \(script)"
        case .ifThen: "If"
        default: type.info.title
        }
    }
}

/// A name a step can use: what an earlier step's output is called, a Repeat's item, the flow's
/// arguments.
public struct FlowVariable: Hashable, Sendable {
    public let name: String
    public let kind: ValueKind
    /// What made it ("Run hello", "Repeat with Each"…).
    public let source: String
}

/// Where a block can go: a position in the top-level list, or in a block's own blocks.
public struct BlockSlot: Equatable, Hashable, Sendable {
    public enum Branch: Hashable, Sendable {
        /// The top-level list (with no parent), an If's Then, a Repeat's steps.
        case body
        /// An If's Otherwise.
        case otherwise
    }
    public var parent: UUID?
    public var branch: Branch
    public var index: Int

    public init(parent: UUID?, branch: Branch = .body, index: Int) {
        self.parent = parent
        self.branch = branch
        self.index = index
    }
}

/// A flow as blocks: the line describing it (shown on its cell) and its steps.
public struct FlowDocument: Equatable, Sendable {
    public var summary: String
    public var blocks: [FlowBlock]

    public init(summary: String = "", blocks: [FlowBlock] = []) {
        self.summary = summary
        self.blocks = blocks
    }

    /// Reads a flow as blocks. Never fails: what isn't a block is a Code block, word for word
    /// (a flow that can't be read at all is one Code block).
    public static func read(_ source: String) -> FlowDocument {
        BlockReader.read(source)
    }

    /// The flow as Flow, and which lines each block is.
    public func written() -> WrittenFlow {
        var w = BlockWriter()
        return w.document(self)
    }
}

/// A flow written from blocks: its text, and the lines each block takes.
public struct WrittenFlow: Sendable {
    public let text: String
    public let lines: [UUID: ClosedRange<Int>]

    /// The innermost block a line of the flow belongs to.
    public func block(atLine line: Int) -> UUID? {
        var best: (UUID, Int)?
        for (id, r) in lines where r.contains(line) {
            if best == nil || r.count < best!.1 { best = (id, r.count) }
        }
        return best?.0
    }
}

// MARK: - Changing a document

extension FlowDocument {
    /// The block with this id, anywhere.
    public func block(_ id: UUID) -> FlowBlock? {
        func find(_ list: [FlowBlock]) -> FlowBlock? {
            for b in list {
                if b.id == id { return b }
                if let f = find(b.children) ?? find(b.otherwise) { return f }
            }
            return nil
        }
        return find(blocks)
    }

    /// Where a block is.
    public func slot(of id: UUID) -> BlockSlot? {
        func find(_ list: [FlowBlock], _ parent: UUID?, _ branch: BlockSlot.Branch) -> BlockSlot? {
            for (k, b) in list.enumerated() {
                if b.id == id { return BlockSlot(parent: parent, branch: branch, index: k) }
                if let s = find(b.children, b.id, .body) ?? find(b.otherwise, b.id, .otherwise) { return s }
            }
            return nil
        }
        return find(blocks, nil, .body)
    }

    /// Changes the list a slot is in (nil when there's no such list).
    @discardableResult
    mutating func withList<R>(_ parent: UUID?, _ branch: BlockSlot.Branch, _ body: (inout [FlowBlock]) -> R) -> R? {
        guard let parent else { return body(&blocks) }
        func visit(_ list: inout [FlowBlock]) -> R? {
            for k in list.indices {
                if list[k].id == parent {
                    return branch == .body ? body(&list[k].children) : body(&list[k].otherwise)
                }
                if let r = visit(&list[k].children) ?? visit(&list[k].otherwise) { return r }
            }
            return nil
        }
        return visit(&blocks)
    }

    /// Changes a block.
    public mutating func update(_ id: UUID, _ change: (inout FlowBlock) -> Void) {
        func visit(_ list: inout [FlowBlock]) -> Bool {
            for k in list.indices {
                if list[k].id == id {
                    change(&list[k])
                    return true
                }
                if visit(&list[k].children) || visit(&list[k].otherwise) { return true }
            }
            return false
        }
        _ = visit(&blocks)
    }

    /// Takes a block out (with the blocks in it). Returns it and where it was.
    @discardableResult
    public mutating func remove(_ id: UUID) -> (FlowBlock, BlockSlot)? {
        guard let slot = slot(of: id) else { return nil }
        guard let b = withList(slot.parent, slot.branch, { $0.remove(at: slot.index) }) else { return nil }
        return (b, slot)
    }

    /// Puts a block in a slot (at its end when the index is past it).
    public mutating func insert(_ block: FlowBlock, at slot: BlockSlot) {
        withList(slot.parent, slot.branch) { list in
            list.insert(block, at: min(max(0, slot.index), list.count))
        }
        if slot.parent != nil, slot.branch == .otherwise { update(slot.parent!) { $0.hasOtherwise = true } }
    }

    /// Whether `id` is `ancestor` or inside it.
    public func isInside(_ id: UUID?, _ ancestor: UUID) -> Bool {
        guard let id else { return false }
        if id == ancestor { return true }
        guard let a = block(ancestor) else { return false }
        func has(_ list: [FlowBlock]) -> Bool { list.contains { $0.id == id || has($0.children) || has($0.otherwise) } }
        return has(a.children) || has(a.otherwise)
    }

    /// Moves a block to a slot (not into itself). Returns whether it moved.
    @discardableResult
    public mutating func move(_ id: UUID, to target: BlockSlot) -> Bool {
        guard !isInside(target.parent, id), let from = slot(of: id) else { return false }
        var to = target
        if from.parent == to.parent, from.branch == to.branch {
            if from.index == to.index || from.index + 1 == to.index { return false }
            if from.index < to.index { to.index -= 1 }
        }
        guard let (b, _) = remove(id) else { return false }
        insert(b, at: to)
        return true
    }

    /// A copy of a block, just after it. Returns the copy's id.
    @discardableResult
    public mutating func duplicate(_ id: UUID) -> UUID? {
        guard let b = block(id), let s = slot(of: id) else { return nil }
        var copy = b.copied()
        if copy.type.hasOutput, !copy.name.isEmpty { copy.name = freeName(copy.name) }
        insert(copy, at: BlockSlot(parent: s.parent, branch: s.branch, index: s.index + 1))
        return copy.id
    }

    /// Every name the flow's steps define (to make new ones that don't clash).
    public var definedNames: Set<String> {
        var names = Set<String>()
        func visit(_ list: [FlowBlock]) {
            for b in list {
                if (b.type.hasOutput || b.type == .repeatEach || b.type == .repeatCount), !b.name.isEmpty { names.insert(b.name) }
                if b.type == .code { names.formUnion(BlockWriter.definedNames(inCode: b.text)) }
                visit(b.children)
                visit(b.otherwise)
            }
        }
        visit(blocks)
        return names
    }

    /// `base`, or `base2`, `base3`… whichever isn't used yet.
    public func freeName(_ base: String) -> String {
        let taken = definedNames.union(Builtin.all.map(\.name)).union(Lexer.keywords).union(["args"])
        let stem = base.isEmpty ? "value" : base
        if !taken.contains(stem) { return stem }
        // "greeting2" → "greeting3", not "greeting22".
        let trimmed = String(stem.reversed().drop(while: \.isNumber).reversed())
        let root = trimmed.isEmpty ? stem : trimmed
        var k = 2
        while taken.contains("\(root)\(k)") { k += 1 }
        return "\(root)\(k)"
    }

    /// The names a block in this slot can use, nearest last.
    public func variables(at slot: BlockSlot) -> [FlowVariable] {
        var found: [FlowVariable]?
        func visit(_ list: [FlowBlock], _ parent: UUID?, _ branch: BlockSlot.Branch, _ env: [FlowVariable]) {
            var env = env
            for (k, b) in list.enumerated() {
                if found != nil { return }
                if parent == slot.parent && branch == slot.branch && k == slot.index {
                    found = env
                    return
                }
                if b.type.isContainer {
                    var inner = env
                    if b.type == .repeatEach || b.type == .repeatCount, !b.name.isEmpty {
                        inner.append(FlowVariable(name: b.name, kind: b.type == .repeatCount ? .number : b.eachLine ? .text : .other, source: b.type.info.title))
                    }
                    visit(b.children, b.id, .body, inner)
                    visit(b.otherwise, b.id, .otherwise, env)
                }
                env = BlockWriter.adding(b, to: env)
            }
            if found == nil && parent == slot.parent && branch == slot.branch && slot.index >= list.count { found = env }
        }
        visit(blocks, nil, .body, [FlowVariable(name: "args", kind: .list, source: "The flow's arguments")])
        let all = found ?? []
        // A name defined again hides the one before.
        var seen = Set<String>()
        return all.reversed().filter { seen.insert($0.name).inserted }.reversed()
    }

    /// The names the block with this id can use.
    public func variables(before id: UUID) -> [FlowVariable] {
        guard let s = slot(of: id) else { return [] }
        return variables(at: s)
    }

    /// Renames what a step's output is called, everywhere it's used after it.
    public mutating func rename(_ old: String, to new: String) {
        guard old != new, !old.isEmpty, !new.isEmpty else { return }
        func fix(_ t: String) -> String { Template.renaming(old, to: new, in: t) }
        func fixCode(_ t: String) -> String { Template.renamingCode(old, to: new, in: t) }
        func visit(_ list: inout [FlowBlock]) {
            for k in list.indices {
                var b = list[k]
                b.text = b.type == .code ? fixCode(b.text) : b.type == .comment ? b.text : fix(b.text)
                b.input = fix(b.input)
                b.args = b.args.map(fix)
                b.number = fix(b.number)
                b.subject = fixCode(b.subject)
                b.condition.subject = fixCode(b.condition.subject)
                b.condition.value = b.condition.bare ? fix(b.condition.value) : fix(b.condition.value)
                visit(&b.children)
                visit(&b.otherwise)
                list[k] = b
            }
        }
        visit(&blocks)
    }
}

// MARK: - New blocks

extension FlowDocument {
    /// A name for a script's output: "disk-space" → diskSpace.
    public static func variableName(for script: String) -> String {
        let base = (script as NSString).deletingPathExtension
        var words: [String] = []
        var current = ""
        for c in base {
            if c.isLetter || c.isNumber {
                current.append(c)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        guard var name = words.first?.lowercased() else { return "output" }
        for w in words.dropFirst() { name += w.prefix(1).uppercased() + w.dropFirst() }
        name = String(name.unicodeScalars.filter { $0.isASCII }.map(Character.init))
        if name.isEmpty || name.first!.isNumber { name = "s" + name }
        if Lexer.keywords.contains(name) || Builtin.all.contains(where: { $0.name == name }) || name == "args" { name += "Output" }
        return name
    }

    /// A name as typed, made into one a flow can use: kept when it already is one ("myList"),
    /// else made from its words ("my list" → myList); one Flow already uses gets "Output" after it.
    public static func identifier(_ typed: String) -> String {
        let t = typed.trimmingCharacters(in: .whitespaces)
        let valid = t.first.map { $0.isASCII && ($0.isLetter || $0 == "_") } == true
            && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "'") }
        guard valid else { return variableName(for: t) }
        if Lexer.keywords.contains(t) || Builtin.all.contains(where: { $0.name == t }) || t == "args" { return t + "Output" }
        return t
    }

    /// A new block of a type, ready to go in a slot: its settings filled in from what's before it
    /// (a Show shows the last step's output; an If tests it).
    public func newBlock(_ type: BlockType, script: String? = nil, at slot: BlockSlot) -> FlowBlock {
        var b = FlowBlock(type)
        let vars = variables(at: slot).filter { $0.name != "args" }
        let last = vars.last
        let lastText = vars.last { $0.kind == .text }
        func hole(_ v: FlowVariable?) -> String {
            guard let v else { return "" }
            return v.kind == .result ? "{\(v.name).out}" : "{\(v.name)}"
        }
        switch type {
        case .runScript:
            b.script = script ?? ""
            b.name = freeName(FlowDocument.variableName(for: script ?? "output"))
        case .shell:
            b.text = "date +%A"
            b.name = freeName("shellOutput")
        case .epa:
            // `script`: a library entry's title, or a command's name.
            let command = EPA.commands.first { $0.title == script } ?? EPA.command(named: script ?? "doctor") ?? EPA.commands[0]
            b.script = command.name
            b.args = command.args
            b.name = freeName(FlowDocument.variableName(for: command.name == "doctor" ? "connections" : command.name))
        case .show, .showResult:
            b.text = last.map(hole) ?? "Hello!"
        case .notify:
            b.text = last.map { "Done: \(hole($0))" } ?? "Done"
        case .confirm:
            b.text = "Go on?"
        case .ask:
            b.text = "What should I use?"
            b.name = freeName("answer")
        case .askYesNo:
            b.text = "Go ahead?"
            b.name = freeName("yes")
        case .choose:
            b.text = "Pick one"
            b.args = ["first", "second"]
            b.name = freeName("choice")
        case .text:
            b.name = freeName("text")
        case .readFile:
            b.text = "~/Desktop/notes.txt"
            b.name = freeName("fileText")
        case .writeFile:
            b.input = "~/Desktop/output.txt"
            b.text = hole(lastText ?? last)
        case .ifThen:
            if let last {
                b.condition = Condition(subject: last.name, test: Condition.Test.offered(for: last.kind)[0])
                if last.kind == .text { b.condition.test = .contains }
            } else {
                b.condition = Condition(test: .answeredYes, value: "Go ahead?")
            }
        case .repeatEach:
            b.subject = (lastText ?? vars.last { $0.kind == .list })?.name ?? "args"
            b.eachLine = (lastText != nil)
            b.name = freeName(b.eachLine ? "line" : "item")
        case .repeatCount:
            b.number = "3"
            b.name = freeName("i")
        case .wait:
            b.number = "2"
        case .stop:
            b.text = "Something went wrong."
        case .comment:
            b.text = "What the next steps are for."
        case .code:
            b.text = "// Any Flow: see the Flow guide\nprint \"hi\""
        }
        return b
    }
}

// MARK: - Templates: text with {values} in it

/// Text fields hold templates: plain text with `{expression}` holes. Written as a Flow text
/// (`"…"`, or `$"…"` with holes), or as the value itself when it's only one hole.
enum Template {
    enum Part: Equatable {
        case text(String)
        case hole(String)
    }

    /// A template's parts. `{{` and `}}` are braces of their own; a `{` never closed is text.
    static func parts(_ t: String) -> [Part] {
        let chars = Array(t)
        var parts: [Part] = []
        var current = ""
        var i = 0
        func flush() {
            if !current.isEmpty { parts.append(.text(current)) }
            current = ""
        }
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                if i + 1 < chars.count && chars[i + 1] == "{" {
                    current.append("{")
                    i += 2
                    continue
                }
                var depth = 1
                var j = i + 1
                while j < chars.count {
                    let d = chars[j]
                    if d == "\"" {
                        j += 1
                        while j < chars.count && chars[j] != "\"" {
                            if chars[j] == "\\" { j += 1 }
                            j += 1
                        }
                    } else if d == "{" {
                        depth += 1
                    } else if d == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j += 1
                }
                if j < chars.count {
                    let inner = String(chars[(i + 1)..<j]).trimmingCharacters(in: .whitespaces)
                    if inner.isEmpty {
                        current += "{}"
                    } else {
                        flush()
                        parts.append(.hole(inner))
                    }
                    i = j + 1
                    continue
                }
                current.append("{")
                i += 1
                continue
            }
            if c == "}" && i + 1 < chars.count && chars[i + 1] == "}" {
                current.append("}")
                i += 2
                continue
            }
            current.append(c)
            i += 1
        }
        flush()
        return parts
    }

    /// Text as a template (its braces doubled, so they stay text).
    static func escaping(_ s: String) -> String {
        s.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
    }

    /// The template a Flow value is: text as it is, a $"…" with its holes, anything else one hole.
    static func of(_ e: Expr) -> String? {
        switch e.kind {
        case let .str(s): return escaping(s)
        case let .interp(texts, holes):
            var t = ""
            for (k, text) in texts.enumerated() {
                t += escaping(text)
                if k < holes.count {
                    guard let h = ExprPrinter.show(holes[k], 0) else { return nil }
                    t += "{\(h)}"
                }
            }
            return t
        default:
            guard let h = ExprPrinter.show(e, 0) else { return nil }
            return "{\(h)}"
        }
    }

    static func quote(_ s: String, interpolated: Bool = false) -> String {
        var out = interpolated ? "$\"" : "\""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            // A Windows or old Mac line end (\r\n is one Character) is a new line, as it would
            // be read from a file: written raw it would be one anyway, and break a // line.
            case "\n", "\r\n", "\r": out += "\\n"
            case "\t": out += "\\t"
            case "{" where interpolated: out += "{{"
            case "}" where interpolated: out += "}}"
            default: out.append(c)
            }
        }
        return out + "\""
    }

    /// The template as a Flow text value, ready for where it goes (`level`: how tightly it must
    /// hold together there). `known`: the names known to hold text (a lone {name} of those is
    /// written as the name).
    static func string(_ t: String, level: Int, known: (Expr) -> Bool) -> String {
        let ps = parts(t)
        if ps.isEmpty { return "\"\"" }
        if ps.count == 1, case let .hole(h) = ps[0], let e = try? parseExpr(h), known(e), let shown = ExprPrinter.show(e, level) {
            return shown
        }
        if !ps.contains(where: { if case .hole = $0 { true } else { false } }) {
            return quote(ps.map { if case let .text(s) = $0 { s } else { "" } }.joined())
        }
        var out = "$\""
        for p in ps {
            switch p {
            case let .text(s): out += String(quote(s, interpolated: true).dropFirst(2).dropLast())
            case let .hole(h): out += "{\(h)}"
            }
        }
        return out + "\""
    }

    /// The template as any value: a lone {hole} is the value itself (for `print`, which takes anything).
    static func value(_ t: String, level: Int) -> String {
        let ps = parts(t)
        if ps.count == 1, case let .hole(h) = ps[0], let e = try? parseExpr(h), let shown = ExprPrinter.show(e, level) { return shown }
        return string(t, level: level, known: { _ in false })
    }

    /// A number: as typed, or a lone {hole}'s value.
    static func number(_ t: String, level: Int) -> String {
        let s = t.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "0" }
        let ps = parts(s)
        let code: String
        if ps.count == 1, case let .hole(h) = ps[0] { code = h } else { code = s }
        if let e = try? parseExpr(code), let shown = ExprPrinter.show(e, level) { return shown }
        // Not Flow (1.5, "two"): written as text read as a number, so the file still reads
        // (as blocks too) and the run says what's wrong with it.
        let asNumber = "int \(quote(code))"
        return level > 9 ? "(\(asNumber))" : asNumber
    }

    /// Flow code as it goes in a place needing `level` (in brackets if it must be).
    static func code(_ c: String, level: Int) -> String {
        let s = c.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "()" }
        if let e = try? parseExpr(s), let shown = ExprPrinter.show(e, level) { return shown }
        return "(\(s))"
    }

    static func parseExpr(_ source: String) throws -> Expr {
        let program = try Parser.parse(source)
        guard case let .block(items) = program.kind, items.count == 1, case let .expr(e) = items[0].kind else {
            throw FlowError(.syntax, nil, "not one expression")
        }
        return e
    }

    private static func renamed(_ old: String, _ new: String, _ source: String) -> String {
        // The name as a whole word, not inside text in quotes, but inside the {holes} of a $"…"
        // (they're code too).
        let chars = Array(source)
        var i = 0
        let oldChars = Array(old)
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "'" }
        func at(_ k: Int, _ c: Character) -> Bool { k < chars.count && chars[k] == c }

        /// Code, up to the } that closes the hole it's in (left for the caller), or to the end.
        func code(inHole: Bool) -> String {
            var out = ""
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if c == "\"" {
                    out += text(interpolated: i > 0 && chars[i - 1] == "$")
                    continue
                }
                // A \"…\" in a hole is text too: $"{name + \"!\"}".
                if inHole && c == "\\" && at(i + 1, "\"") {
                    out += "\\\""
                    i += 2
                    while i < chars.count && !(chars[i] == "\\" && at(i + 1, "\"")) {
                        out.append(chars[i])
                        i += 1
                    }
                    if i < chars.count { out += "\\\""; i += 2 }
                    continue
                }
                if inHole && c == "{" { depth += 1 }
                if inHole && c == "}" {
                    if depth == 0 { return out }
                    depth -= 1
                }
                if i + oldChars.count <= chars.count, Array(chars[i..<(i + oldChars.count)]) == oldChars,
                   i == 0 || (!isWord(chars[i - 1]) && chars[i - 1] != "."),
                   i + oldChars.count == chars.count || !isWord(chars[i + oldChars.count]) {
                    out += new
                    i += oldChars.count
                    continue
                }
                out.append(c)
                i += 1
            }
            return out
        }

        /// A text, from its opening quote to its closing one: as it is, but its holes renamed.
        func text(interpolated: Bool) -> String {
            var out = "\""
            i += 1
            while i < chars.count && chars[i] != "\"" {
                if chars[i] == "\\" && i + 1 < chars.count {
                    out.append(chars[i])
                    out.append(chars[i + 1])
                    i += 2
                    continue
                }
                if interpolated && chars[i] == "{" {
                    if at(i + 1, "{") {
                        out += "{{"
                        i += 2
                        continue
                    }
                    i += 1
                    out += "{" + code(inHole: true)
                    if i < chars.count { out.append(chars[i]); i += 1 }
                    continue
                }
                out.append(chars[i])
                i += 1
            }
            if i < chars.count { out.append(chars[i]); i += 1 }
            return out
        }

        return code(inHole: false)
    }

    /// A template with a name renamed in its holes.
    static func renaming(_ old: String, to new: String, in t: String) -> String {
        var out = ""
        for p in parts(t) {
            switch p {
            case let .text(s): out += escaping(s)
            case let .hole(h): out += "{\(renamed(old, new, h))}"
            }
        }
        return out
    }

    /// Flow code with a name renamed.
    static func renamingCode(_ old: String, to new: String, in code: String) -> String { renamed(old, new, code) }
}

// MARK: - Expressions back to Flow

/// Writes an expression as Flow, with brackets only where they're needed. `level` is how tightly
/// what's written must hold together where it goes: 0 anywhere, 1 not a `fun`/`if`/`for` (those
/// run to the end), up to 10 an argument (only a value or a field). Nil when it can't be written
/// on one line (a block of several steps).
enum ExprPrinter {
    static func level(_ e: Expr) -> Int? {
        switch e.kind {
        case let .int(n): return n < 0 ? 8 : 11
        case .str, .interp, .bool, .unit, .list, .name: return 11
        case .field: return 10
        case let .apply(f, _):
            if case let .apply(g, _) = f.kind, case .name(Builtin.forName) = g.kind { return 0 }
            return 9
        case .lambda: return compose(e) != nil ? 1 : 0
        case let .binary(op, _, _): return binaryLevel(op)
        case .negate: return 8
        case .cond: return 0
        case let .block(items):
            guard items.count == 1, case let .expr(x) = items[0].kind else { return nil }
            return level(x)
        }
    }

    static func binaryLevel(_ op: String) -> Int {
        switch op {
        case "||": 2
        case "&&": 3
        case "@": 5
        case "+", "-": 6
        case "*", "/", "%": 7
        default: 4
        }
    }

    /// `f >> g`, which the parser makes into `fun $x -> g (f $x)`.
    static func compose(_ e: Expr) -> (Expr, Expr)? {
        guard case let .lambda(params, body) = e.kind, params.count == 1, let p = params[0].name, p.hasPrefix("$x"),
              case let .apply(g, inner) = body.kind, case let .apply(f, arg) = inner.kind, case .name(p) = arg.kind else { return nil }
        return (f, g)
    }

    static func show(_ e: Expr, _ min: Int) -> String? {
        guard let lv = level(e), let s = plain(e) else { return nil }
        return lv < min ? "(\(s))" : s
    }

    private static func plain(_ e: Expr) -> String? {
        switch e.kind {
        case let .int(n): return String(n)
        case let .str(s): return Template.quote(s)
        case let .interp(texts, holes):
            var out = "$\""
            for (k, t) in texts.enumerated() {
                out += String(Template.quote(t, interpolated: true).dropFirst(2).dropLast())
                if k < holes.count {
                    guard let h = show(holes[k], 0) else { return nil }
                    out += "{\(h)}"
                }
            }
            return out + "\""
        case let .bool(b): return b ? "true" : "false"
        case .unit: return "()"
        case let .list(items):
            var parts: [String] = []
            for x in items {
                guard let s = show(x, 1) else { return nil }
                parts.append(s)
            }
            return "[" + parts.joined(separator: "; ") + "]"
        case let .name(n): return n == Builtin.forName ? nil : n
        case let .field(x, name):
            guard let s = show(x, 10) else { return nil }
            return "\(s).\(name)"
        case let .apply(f, a):
            if case let .apply(g, fn) = f.kind, case .name(Builtin.forName) = g.kind,
               case let .lambda(params, body) = fn.kind, params.count == 1, let n = params[0].name {
                guard let xs = show(a, 1), let b = show(body, 0) else { return nil }
                return "for \(n) in \(xs) do \(b)"
            }
            var args: [Expr] = [a]
            var head = f
            while case let .apply(g, x) = head.kind {
                args.insert(x, at: 0)
                head = g
            }
            guard let h = show(head, 10) else { return nil }
            var out = h
            for x in args {
                guard let s = show(x, 10) else { return nil }
                out += " " + s
            }
            return out
        case let .lambda(params, body):
            if let (f, g) = compose(e) {
                guard let l = show(f, 1), let r = show(g, 2) else { return nil }
                return "\(l) >> \(r)"
            }
            guard let b = show(body, 0) else { return nil }
            return "fun " + params.map { $0.name ?? "()" }.joined(separator: " ") + " -> " + b
        case let .binary(op, l, r):
            let lv = binaryLevel(op)
            let (ll, rl) = op == "@" ? (lv + 1, lv) : lv == 4 ? (lv + 1, lv + 1) : (lv, lv + 1)
            guard let ls = show(l, ll), let rs = show(r, rl) else { return nil }
            return "\(ls) \(op) \(rs)"
        case let .negate(x):
            guard let s = show(x, 8) else { return nil }
            return s.hasPrefix("-") ? "- \(s)" : "-\(s)"
        case let .cond(test, yes, no):
            guard let t = show(test, 0) else { return nil }
            guard let y = show(yes, no == nil ? 0 : 1) else { return nil }
            guard let no else { return "if \(t) then \(y)" }
            guard let n = show(no, 0) else { return nil }
            return "if \(t) then \(y) else \(n)"
        case let .block(items):
            guard items.count == 1, case let .expr(x) = items[0].kind else { return nil }
            return plain(x)
        }
    }

    /// The function at the front of `f a b` and what it's given, when it's a name.
    static func spine(_ e: Expr) -> (String, [Expr])? {
        var args: [Expr] = []
        var head = e
        while case let .apply(f, a) = head.kind {
            args.insert(a, at: 0)
            head = f
        }
        guard case let .name(n) = head.kind, !args.isEmpty else { return nil }
        return (n, args)
    }
}

// MARK: - Writing blocks as Flow

struct BlockWriter {
    private(set) var out: [String] = []
    private(set) var ranges: [UUID: ClosedRange<Int>] = [:]
    static let indent = "    "

    mutating func document(_ doc: FlowDocument) -> WrittenFlow {
        out = []
        ranges = [:]
        let summary = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            out.append("// " + Self.lines(summary).joined(separator: " "))
        }
        list(doc.blocks, depth: 0, env: Self.start, useOriginals: true, top: true)
        // With no summary, a first line that's a comment would be read as one: an empty one
        // goes first, so the comment stays a block.
        if summary.isEmpty, let first = out.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            out.insert("//", at: 0)
            ranges = ranges.mapValues { ($0.lowerBound + 1)...($0.upperBound + 1) }
        }
        var text = out.joined(separator: "\n")
        if !text.isEmpty { text += "\n" }
        return WrittenFlow(text: text, lines: ranges)
    }

    static let start = [FlowVariable(name: "args", kind: .list, source: "The flow's arguments")]

    /// Blocks one after another. A branch with no step in it gets `()` (a step that does nothing).
    private mutating func list(_ blocks: [FlowBlock], depth: Int, env: [FlowVariable], useOriginals: Bool, top: Bool) {
        var env = env
        var wroteCode = false
        for (k, b) in blocks.enumerated() {
            // A blank line where there was one, and around a new If or Repeat at the top (the
            // file's own layout is left as it was).
            let fromFile = b.original != nil && (k == 0 || blocks[k - 1].original != nil)
            // Two comments one after the other would be read as one: a blank line keeps them two.
            let blank = b.blankBefore || (top && k > 0 && !fromFile && (b.type.isContainer || blocks[k - 1].type.isContainer))
                || (k > 0 && b.type == .comment && blocks[k - 1].type == .comment)
            if blank && (k > 0 || top) && !(out.last?.isEmpty ?? true) { out.append("") }
            emit(b, depth: depth, env: env, useOriginals: useOriginals)
            if b.type != .comment && !(b.type == .code && Self.isOnlyComments(b.text)) { wroteCode = true }
            env = Self.adding(b, to: env)
        }
        if !top && !wroteCode { out.append(String(repeating: Self.indent, count: depth) + "()") }
    }

    /// One block, at `depth`.
    private mutating func emit(_ b: FlowBlock, depth: Int, env: [FlowVariable], useOriginals: Bool) {
        let pad = String(repeating: Self.indent, count: depth)
        let first = out.count + 1
        if useOriginals, let original = b.original, let canonical = b.canonical,
           Self.fresh(b, env: env).joined(separator: "\n") == canonical {
            out += Self.indented(original.components(separatedBy: "\n"), pad: pad)
            ranges[b.id] = first...max(first, out.count)
            Self.originalRanges(b, start: first, into: &ranges)
            return
        }
        if b.type.isContainer {
            let name = b.name.isEmpty ? (b.type == .repeatCount ? "i" : "item") : b.name
            switch b.type {
            case .ifThen:
                out.append(pad + "if \(Self.condition(b.condition, env)) then")
            case .repeatEach:
                let items = b.eachLine ? "lines \(Template.code(b.subject, level: 10))" : Template.code(b.subject, level: 1)
                out.append(pad + "for \(name) in \(items) do")
            default:
                out.append(pad + "for \(name) in range 1 \(Template.number(b.number, level: 10)) do")
            }
            var inner = env
            if b.type != .ifThen { inner.append(Self.loopVariable(b, name: name)) }
            list(b.children, depth: depth + 1, env: inner, useOriginals: useOriginals, top: false)
            if b.type == .ifThen && (b.hasOtherwise || !b.otherwise.isEmpty) {
                out.append(pad + "else")
                list(b.otherwise, depth: depth + 1, env: env, useOriginals: useOriginals, top: false)
            }
        } else {
            out += Self.indented(Self.step(b, env: env), pad: pad)
        }
        if out.count >= first { ranges[b.id] = first...out.count }
    }

    static func loopVariable(_ b: FlowBlock, name: String) -> FlowVariable {
        FlowVariable(name: name, kind: b.type == .repeatCount ? .number : b.eachLine ? .text : .other, source: b.type.info.title)
    }

    /// The blocks inside a block written as it was in the file: their lines as they were.
    static func originalRanges(_ b: FlowBlock, start: Int, into ranges: inout [UUID: ClosedRange<Int>]) {
        for c in b.children + b.otherwise {
            if let r = c.originalLines {
                ranges[c.id] = (start + r.lowerBound)...(start + r.upperBound)
                originalRanges(c, start: start + r.lowerBound, into: &ranges)
            }
        }
    }

    /// A block as it's written now, ignoring how it was in the file (its blocks inside too).
    static func fresh(_ b: FlowBlock, env: [FlowVariable]) -> [String] {
        var w = BlockWriter()
        w.emit(b, depth: 0, env: env, useOriginals: false)
        return w.out
    }

    /// Code with nothing in it but comments (`//`, `#`, `(* … *)`) and blank lines. Code that
    /// can't even be read counts as code.
    static func isOnlyComments(_ code: String) -> Bool {
        guard let tokens = try? Lexer.tokenize(code) else { return false }
        return tokens.allSatisfy { $0.kind == .eof }
    }

    /// Text's lines, whatever ends them (\n, \r\n or \r: the lexer reads each as a new line).
    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    }

    /// The lines (counted from 0) that carry on a text in quotes begun on a line before: they're
    /// part of the text, so moving them in or out would change what it says.
    static func textLines(_ lines: [String]) -> Set<Int> {
        guard lines.count > 1, let tokens = try? Lexer.tokenize(lines.joined(separator: "\n")) else { return [] }
        var inside = Set<Int>()
        for t in tokens where t.end.line > t.pos.line {
            switch t.kind {
            case .string, .interpolated: for l in (t.pos.line + 1)...t.end.line { inside.insert(l - 1) }
            default: break
            }
        }
        return inside
    }

    /// Lines moved in by `pad` (blank ones left empty, and ones inside a text left as they are).
    static func indented(_ lines: [String], pad: String) -> [String] {
        guard !pad.isEmpty else { return lines }
        let inside = textLines(lines)
        return lines.enumerated().map { k, line in line.isEmpty || inside.contains(k) ? line : pad + line }
    }

    /// Lines with the indent they all have taken off (not counting blank ones, or ones inside a text).
    static func dedented(_ lines: [String]) -> [String] {
        let inside = textLines(lines)
        func indent(_ l: String) -> Int { l.prefix { $0 == " " || $0 == "\t" }.count }
        let counted = lines.enumerated().filter { k, l in !inside.contains(k) && !l.trimmingCharacters(in: .whitespaces).isEmpty }
        let common = counted.map { indent($0.element) }.min() ?? 0
        guard common > 0 else { return lines }
        return lines.enumerated().map { k, l in inside.contains(k) ? l : String(l.dropFirst(min(common, indent(l)))) }
    }

    /// What a block's output adds to the names after it.
    static func adding(_ b: FlowBlock, to env: [FlowVariable]) -> [FlowVariable] {
        var env = env
        if b.type.hasOutput, !b.name.isEmpty {
            let kind: ValueKind = switch b.type {
            case .runScript, .epa: b.keepGoing ? .result : .text
            case .askYesNo: .bool
            default: .text
            }
            env.append(FlowVariable(name: b.name, kind: kind, source: b.headline))
        }
        if b.type == .code {
            for n in definedNames(inCode: b.text) { env.append(FlowVariable(name: n, kind: .other, source: "Flow Code")) }
        }
        return env
    }

    /// The names a piece of Flow code defines at its top (`let name …`).
    static func definedNames(inCode code: String) -> [String] {
        var names: [String] = []
        for raw in code.split(separator: "\n") {
            guard !raw.hasPrefix(" "), !raw.hasPrefix("\t") else { continue }
            var words = raw.split(separator: " ").map(String.init)
            guard words.first == "let" else { continue }
            words.removeFirst()
            if words.first == "rec" { words.removeFirst() }
            if let n = words.first, let c = n.first, c.isLetter || c == "_",
               n.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "'" }) { names.append(n) }
        }
        return names
    }

    /// The names known to hold text, for writing a lone {name} as the name.
    static func knownText(_ env: [FlowVariable]) -> (Expr) -> Bool {
        // A name defined again is what it was made last.
        var kinds: [String: ValueKind] = [:]
        for v in env { kinds[v.name] = v.kind }
        let text = Set(kinds.filter { $0.value == .text }.keys)
        let results = Set(kinds.filter { $0.value == .result }.keys)
        return { e in
            switch e.kind {
            case .str, .interp: return true
            case let .name(n): return text.contains(n)
            case let .field(x, f):
                if case let .name(n) = x.kind { return results.contains(n) && (f == "out" || f == "err") }
                return false
            default: return false
            }
        }
    }

    static func kind(of subject: String, _ env: [FlowVariable]) -> ValueKind {
        let s = subject.trimmingCharacters(in: .whitespaces)
        return env.last { $0.name == s }?.kind ?? .other
    }

    /// A step's lines (anything but an If or a Repeat).
    static func step(_ b: FlowBlock, env: [FlowVariable]) -> [String] {
        let known = knownText(env)
        func str(_ t: String, _ level: Int = 10) -> String { Template.string(t, level: level, known: known) }
        func named(_ value: String) -> String {
            b.name.isEmpty ? "\(value) |> ignore" : "let \(b.name) = \(value)"
        }
        switch b.type {
        case .comment:
            return lines(b.text).map { $0.isEmpty ? "//" : "// " + $0 }
        case .code:
            // Its own indent taken off: it goes where the block is (an indented first line would
            // carry on the step before it).
            var code = dedented(lines(b.text))
            while let last = code.last, last.trimmingCharacters(in: .whitespaces).isEmpty { code.removeLast() }
            return code
        case .runScript:
            let fn = b.keepGoing ? (b.input.isEmpty ? "attempt" : "attemptPipe") : (b.input.isEmpty ? "run" : "pipe")
            let call = "\(fn) \(Template.quote(b.script)) [\(b.args.map { str($0, 1) }.joined(separator: "; "))]"
            return [named(b.input.isEmpty ? call : "\(str(b.input, 1)) |> \(call)")]
        case .shell: return [named("sh \(str(b.text))")]
        case .epa:
            let words = [Template.quote(b.script)] + b.args.map { str($0, 1) }
            return [named("\(b.keepGoing ? "attemptEpa" : "epa") [\(words.joined(separator: "; "))]")]
        // With a why, the …Because form: the question, then why, (then the choices).
        case .ask: return [named(b.why.isEmpty ? "ask \(str(b.text))" : "askBecause \(str(b.text)) \(str(b.why))")]
        case .askYesNo: return [named(b.why.isEmpty ? "askYesNo \(str(b.text))" : "askYesNoBecause \(str(b.text)) \(str(b.why))")]
        case .choose:
            let choices = "[\(b.args.map { str($0, 1) }.joined(separator: "; "))]"
            return [named(b.why.isEmpty ? "choose \(str(b.text)) \(choices)" : "chooseBecause \(str(b.text)) \(str(b.why)) \(choices)")]
        // Text is always written as text (a lone {name} as $"{name}"), so it reads back as Text.
        case .text: return [named(Template.string(b.text, level: 1, known: { e in if case .str = e.kind { true } else { false } }))]
        case .readFile: return [named("read \(str(b.text))")]
        case .show: return ["print \(Template.value(b.text, level: 10))"]
        case .showResult: return ["showResult \(str(b.text))"]
        case .notify: return ["notify \(str(b.text))"]
        case .confirm: return [b.why.isEmpty ? "confirm \(str(b.text))" : "confirmBecause \(str(b.text)) \(str(b.why))"]
        case .stop: return ["fail \(str(b.text))"]
        case .writeFile: return ["write \(str(b.input)) \(str(b.text))"]
        case .wait: return ["sleep \(Template.number(b.number, level: 10))"]
        case .ifThen, .repeatEach, .repeatCount: return fresh(b, env: env)
        }
    }

    /// An If's test as Flow.
    static func condition(_ c: Condition, _ env: [FlowVariable]) -> String {
        let known = knownText(env)
        let kind = kind(of: c.subject, env)
        // The subject where an operator's side goes, or as an argument.
        func subject(_ level: Int) -> String {
            if c.asNumber { return level >= 9 ? "(int \(Template.code(c.subject, level: 10)))" : "int \(Template.code(c.subject, level: 10))" }
            return Template.code(c.subject, level: level)
        }
        func value(_ level: Int) -> String {
            c.bare ? Template.number(c.value, level: level) : Template.string(c.value, level: level, known: known)
        }
        func compare(_ op: String) -> String {
            let v = c.test.numeric ? Template.number(c.value, level: 5) : value(5)
            return "\(subject(5)) \(op) \(v)"
        }
        switch c.test {
        case .equals: return compare("=")
        case .notEquals: return compare("<>")
        case .greater: return compare(">")
        case .less: return compare("<")
        case .atLeast: return compare(">=")
        case .atMost: return compare("<=")
        case .contains: return "contains \(value(10)) \(subject(10))"
        case .notContains: return "not (contains \(value(10)) \(subject(10)))"
        case .startsWith: return "startsWith \(value(10)) \(subject(10))"
        case .endsWith: return "endsWith \(value(10)) \(subject(10))"
        case .isEmpty: return kind == .text ? "trim \(subject(10)) = \"\"" : "isEmpty \(subject(10))"
        case .notEmpty: return kind == .text ? "trim \(subject(10)) <> \"\"" : "not (isEmpty \(subject(10)))"
        case .succeeded: return "\(subject(10)).ok"
        case .failed: return "not \(subject(10)).ok"
        case .isTrue: return subject(1)
        case .isFalse: return "not \(subject(10))"
        case .exists: return "exists \(Template.string(c.value, level: 10, known: known))"
        case .notExists: return "not (exists \(Template.string(c.value, level: 10, known: known)))"
        case .answeredYes: return "askYesNo \(Template.string(c.value, level: 10, known: known))"
        case .code: return Template.code(c.subject, level: 1)
        }
    }
}

// MARK: - Reading Flow as blocks

struct BlockReader {
    private let lines: [String]
    private let commentLines: Set<Int>
    private var codeLines = Set<Int>()
    /// Lines that carry on a text in quotes begun on a line before (kept as they are: their
    /// spaces are the text's).
    private var textLines = Set<Int>()
    /// Comment lines that went into a block (the rest of a container's mean it's kept as code).
    private var used = Set<Int>()

    private init(lines: [String], comments: Set<Int>, tokens: [Token]) {
        self.lines = lines
        commentLines = comments
        for t in tokens where t.kind != .eof {
            for l in t.pos.line...max(t.pos.line, t.end.line) { codeLines.insert(l) }
            switch t.kind {
            case .string, .interpolated:
                if t.end.line > t.pos.line { for l in (t.pos.line + 1)...t.end.line { textLines.insert(l) } }
            default: break
            }
        }
    }

    static func read(_ source: String, check: Bool = true) -> FlowDocument {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // A byte-order mark some editors put first isn't part of the flow.
        if text.unicodeScalars.first == "\u{FEFF}" { text = String(text.unicodeScalars.dropFirst()) }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // The first line, a comment, is what the flow does (shown on its cell).
        var summary = ""
        var from = 1
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("//") {
            summary = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
            from = 2
        }
        guard let (tokens, comments) = try? Lexer.scan(text), let program = try? Parser.parse(tokens: tokens),
              case let .block(items) = program.kind else {
            var code = FlowBlock(.code)
            code.text = lines.dropFirst(from - 1).joined(separator: "\n")
            return FlowDocument(summary: summary, blocks: code.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [code])
        }
        var reader = BlockReader(lines: lines, comments: comments, tokens: tokens)
        var blocks = reader.list(items, from: from, to: lines.count, col: 1, origin: 1)
        // What each block would be written as, to know later whether it was changed; a block
        // that doesn't read back the same is kept as code.
        var env = BlockWriter.start
        settle(&blocks, env: &env, check: check)
        return FlowDocument(summary: summary, blocks: blocks)
    }

    /// Works out each block's Flow (blocks inside first); one that doesn't read back as itself
    /// becomes code, as it was.
    private static func settle(_ blocks: inout [FlowBlock], env: inout [FlowVariable], check: Bool) {
        for k in blocks.indices {
            var b = blocks[k]
            if b.type.isContainer {
                var inner = env
                if b.type != .ifThen { inner.append(BlockWriter.loopVariable(b, name: b.name)) }
                settle(&b.children, env: &inner, check: check)
                var other = env
                settle(&b.otherwise, env: &other, check: check)
            }
            let fresh = BlockWriter.fresh(b, env: env).joined(separator: "\n")
            if check && b.type != .code && b.type != .comment {
                let again = BlockReader.read(fresh, check: false).blocks
                if again.count != 1 || again[0].content() != b.content() {
                    var code = FlowBlock(.code)
                    code.text = b.original ?? fresh
                    code.original = b.original
                    code.originalLines = b.originalLines
                    code.blankBefore = b.blankBefore
                    code.id = b.id
                    b = code
                }
            }
            b.canonical = BlockWriter.fresh(b, env: env).joined(separator: "\n")
            env = BlockWriter.adding(b, to: env)
            blocks[k] = b
        }
    }

    private func isCommentOnly(_ l: Int) -> Bool { commentLines.contains(l) && !codeLines.contains(l) }

    private func isBlank(_ l: Int) -> Bool {
        guard l >= 1 && l <= lines.count else { return true }
        return !codeLines.contains(l) && !commentLines.contains(l) && lines[l - 1].trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func indentOf(_ l: Int) -> Int {
        guard l >= 1 && l <= lines.count else { return 0 }
        return lines[l - 1].prefix { $0 == " " || $0 == "\t" }.count
    }

    /// Lines `from`…`to`, with `col - 1` columns of indent taken off.
    private func text(_ from: Int, _ to: Int, col: Int) -> String {
        guard from <= to, from >= 1, to <= lines.count else { return "" }
        return (from...to).map { l in
            let line = lines[l - 1]
            if textLines.contains(l) { return line }
            let pad = min(col - 1, line.prefix { $0 == " " || $0 == "\t" }.count)
            return String(line.dropFirst(pad))
        }.joined(separator: "\n")
    }

    /// The items of a block, between lines `from` and `to` (the comments between them are blocks too).
    /// `origin`: the first line of the block they're in (for where each was).
    private mutating func list(_ items: [Item], from: Int, to: Int, col: Int, origin: Int) -> [FlowBlock] {
        var blocks: [FlowBlock] = []
        var cursor = from
        var blank = false
        func gap(_ until: Int) {
            guard cursor <= until else { return }
            var l = cursor
            while l <= until {
                if isCommentOnly(l) {
                    var end = l
                    while end + 1 <= until && isCommentOnly(end + 1) { end += 1 }
                    var c = FlowBlock(.comment)
                    c.text = (l...end).map { BlockReader.commentText(lines[$0 - 1]) }.joined(separator: "\n")
                    c.original = text(l, end, col: col)
                    c.originalLines = (l - origin)...(end - origin)
                    c.blankBefore = blank
                    blank = false
                    blocks.append(c)
                    for k in l...end { used.insert(k) }
                    l = end + 1
                    continue
                }
                if isBlank(l) { blank = true }
                l += 1
            }
        }
        for (k, item) in items.enumerated() {
            gap(item.pos.line - 1)
            var end = max(item.pos.line, item.end.line)
            if Self.isContainer(item) {
                end = trailingComments(after: end, until: k + 1 < items.count ? items[k + 1].pos.line - 1 : to, col: item.pos.col)
            }
            // A `()` a branch needed: the writer puts it back when it's needed.
            if col > 1, case let .expr(x) = item.kind, case .unit = x.kind, !commentLines.contains(item.pos.line) {
                cursor = end + 1
                continue
            }
            var b = self.item(item, end: end)
            b.blankBefore = blank
            blank = false
            b.original = text(item.pos.line, end, col: item.pos.col)
            b.originalLines = (item.pos.line - origin)...(end - origin)
            blocks.append(b)
            cursor = end + 1
        }
        gap(to)
        return blocks
    }

    /// A container's last block can end with comments indented under it.
    private func trailingComments(after end: Int, until limit: Int, col: Int) -> Int {
        var last = end
        var l = end + 1
        while l <= limit {
            if isBlank(l) {
                l += 1
                continue
            }
            if isCommentOnly(l) && indentOf(l) >= col {
                last = l
                l += 1
                continue
            }
            break
        }
        return last
    }

    static func isContainer(_ item: Item) -> Bool {
        guard case let .expr(e) = item.kind else { return false }
        if case .cond = e.kind { return true }
        if let (head, args) = ExprPrinter.spine(e), head == Builtin.forName || head == "each", args.count == 2,
           case .lambda = args[0].kind { return true }
        return false
    }

    /// A comment line's text: after its `//` or `#`, or inside its `(*` `*)` (a line with
    /// neither is inside a `(* … *)` across lines). What's after a `//` is kept as it is.
    static func commentText(_ line: String) -> String {
        var t = String(line.drop { $0 == " " || $0 == "\t" })
        if t.hasPrefix("//") {
            t = String(t.dropFirst(2))
        } else if t.hasPrefix("#") {
            t = String(t.dropFirst(1))
        } else {
            t = t.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("(*") { t = String(t.dropFirst(2)) }
            if t.hasSuffix("*)") { t = String(t.dropLast(2)) }
            t = t.trimmingCharacters(in: .whitespaces)
            return t
        }
        if t.hasPrefix(" ") { t = String(t.dropFirst()) }
        return t
    }

    private static func code(_ text: String) -> FlowBlock {
        var b = FlowBlock(.code)
        b.text = text
        return b
    }

    /// One item as a block (code, as it was, if it's no block).
    private mutating func item(_ item: Item, end: Int) -> FlowBlock {
        let original = text(item.pos.line, end, col: item.pos.col)
        let before = used
        let range = item.pos.line...end
        if Self.isContainer(item), case let .expr(e) = item.kind, let b = container(e, end: end) {
            // Every comment in it went into a block of its own: it's a block.
            if range.allSatisfy({ !commentLines.contains($0) || used.contains($0) }) { return b }
            used = before
            return Self.code(original)
        }
        if range.contains(where: { commentLines.contains($0) }) { return Self.code(original) }
        return Self.simple(item) ?? Self.code(original)
    }

    /// An item that's one step (no blocks inside).
    static func simple(_ item: Item) -> FlowBlock? {
        switch item.kind {
        case let .bind(name, rec, params, body):
            guard !rec, params.isEmpty else { return nil }
            guard var b = value(single(body)) else { return nil }
            b.name = name
            return b
        case let .expr(e):
            return statement(e)
        }
    }

    static func single(_ e: Expr) -> Expr {
        if case let .block(items) = e.kind, items.count == 1, case let .expr(x) = items[0].kind { return x }
        return e
    }

    /// A step that makes a value (what's after `let name =`).
    static func value(_ e: Expr) -> FlowBlock? {
        switch e.kind {
        case .str, .interp:
            var b = FlowBlock(.text)
            guard let t = Template.of(e) else { return nil }
            b.text = t
            return b
        default: break
        }
        guard let (head, args) = ExprPrinter.spine(e) else { return nil }
        func strings(_ x: Expr) -> [String]? {
            guard case let .list(items) = x.kind else { return nil }
            var out: [String] = []
            for i in items {
                guard let t = Template.of(i) else { return nil }
                out.append(t)
            }
            return out
        }
        switch (head, args.count) {
        case ("run", 2), ("attempt", 2), ("pipe", 3), ("attemptPipe", 3):
            guard case let .str(script) = args[0].kind, let list = strings(args[1]) else { return nil }
            var b = FlowBlock(.runScript)
            b.script = script
            b.args = list
            b.keepGoing = head.hasPrefix("attempt")
            if args.count == 3 {
                guard let input = Template.of(args[2]) else { return nil }
                b.input = input
                if b.input.isEmpty { return nil }
            }
            return b
        case ("epa", 1), ("attemptEpa", 1):
            guard let words = strings(args[0]), let command = words.first, !command.isEmpty,
                  case let .list(items) = args[0].kind, case .str = items[0].kind else { return nil }
            var b = FlowBlock(.epa)
            b.script = command
            b.args = Array(words.dropFirst())
            b.keepGoing = head == "attemptEpa"
            return b
        case ("sh", 1), ("ask", 1), ("askYesNo", 1), ("read", 1):
            let type: BlockType = head == "sh" ? .shell : head == "ask" ? .ask : head == "askYesNo" ? .askYesNo : .readFile
            var b = FlowBlock(type)
            guard let t = Template.of(args[0]) else { return nil }
            b.text = t
            return b
        case ("choose", 2):
            guard let t = Template.of(args[0]), let options = strings(args[1]) else { return nil }
            var b = FlowBlock(.choose)
            b.text = t
            b.args = options
            return b
        case ("askBecause", 2), ("askYesNoBecause", 2):
            var b = FlowBlock(head == "askBecause" ? .ask : .askYesNo)
            guard let t = Template.of(args[0]), let why = Template.of(args[1]), !why.isEmpty else { return nil }
            b.text = t
            b.why = why
            return b
        case ("chooseBecause", 3):
            guard let t = Template.of(args[0]), let why = Template.of(args[1]), !why.isEmpty, let options = strings(args[2]) else { return nil }
            var b = FlowBlock(.choose)
            b.text = t
            b.why = why
            b.args = options
            return b
        default:
            return nil
        }
    }

    /// A number field: the number, or {the value} it's worked out from.
    static func number(_ e: Expr) -> String? {
        if case let .int(n) = e.kind { return String(n) }
        return ExprPrinter.show(e, 0).map { "{\($0)}" }
    }

    /// A step on its own line (not a `let`).
    static func statement(_ e: Expr) -> FlowBlock? {
        guard let (head, args) = ExprPrinter.spine(e) else { return nil }
        switch (head, args.count) {
        case ("print", 1):
            var b = FlowBlock(.show)
            guard let t = Template.of(args[0]) else { return nil }
            b.text = t
            return b
        case ("notify", 1), ("confirm", 1), ("fail", 1), ("showResult", 1):
            var b = FlowBlock(head == "notify" ? .notify : head == "confirm" ? .confirm : head == "showResult" ? .showResult : .stop)
            guard let t = Template.of(args[0]) else { return nil }
            b.text = t
            return b
        case ("confirmBecause", 2):
            var b = FlowBlock(.confirm)
            guard let t = Template.of(args[0]), let why = Template.of(args[1]), !why.isEmpty else { return nil }
            b.text = t
            b.why = why
            return b
        case ("sleep", 1):
            var b = FlowBlock(.wait)
            guard let n = number(args[0]) else { return nil }
            b.number = n
            return b
        case ("write", 2):
            var b = FlowBlock(.writeFile)
            guard let p = Template.of(args[0]), let t = Template.of(args[1]) else { return nil }
            b.input = p
            b.text = t
            return b
        case ("ignore", 1):
            guard var b = value(args[0]), b.type != .text else { return nil }
            b.name = ""
            return b
        default:
            return nil
        }
    }

    /// An If, or a Repeat, with the blocks inside it.
    private mutating func container(_ e: Expr, end: Int) -> FlowBlock? {
        let origin = e.pos.line
        // The blocks of a branch: on the lines under its keyword (`then`, `else`, `do`, `->`), up to `to`.
        func branch(_ x: Expr, keyword: Pos?, to: Int) -> [FlowBlock]? {
            if case let .block(items) = x.kind, let keyword, let first = items.first, first.pos.line > keyword.line {
                return list(items, from: keyword.line + 1, to: to, col: first.pos.col, origin: origin)
            }
            // One step on the keyword's line.
            let one = Item(kind: .expr(Self.single(x)), pos: x.pos)
            if Self.isContainer(one) {
                guard case let .expr(inner) = one.kind, let b = container(inner, end: end) else { return nil }
                return [b]
            }
            guard let b = Self.simple(one) else { return nil }
            return [b]
        }
        switch e.kind {
        case let .cond(test, yes, no):
            var b = FlowBlock(.ifThen)
            guard let c = Self.condition(test) else { return nil }
            b.condition = c
            let thenPos = e.marks.first
            let elsePos = e.marks.count > 1 ? e.marks[1] : nil
            guard let children = branch(yes, keyword: thenPos, to: (elsePos?.line ?? end + 1) - 1) else { return nil }
            b.children = children
            if let no {
                // `elif`: an If inside Otherwise.
                if case .cond = no.kind, let elsePos, elsePos.line == no.pos.line, elsePos.col == no.pos.col {
                    guard let inner = container(no, end: end) else { return nil }
                    b.otherwise = [inner]
                } else {
                    guard let other = branch(no, keyword: elsePos, to: end) else { return nil }
                    b.otherwise = other
                }
                b.hasOtherwise = true
            }
            return b
        default:
            guard let (head, args) = ExprPrinter.spine(e), args.count == 2,
                  case let .lambda(params, body) = args[0].kind, params.count == 1, let name = params[0].name else { return nil }
            let keyword = head == Builtin.forName ? e.marks.first : args[0].marks.first
            var b: FlowBlock
            if let (h, a) = ExprPrinter.spine(args[1]), h == "range", a.count == 2, case .int(1) = a[0].kind {
                b = FlowBlock(.repeatCount)
                guard let n = Self.number(a[1]) else { return nil }
                b.number = n
            } else {
                b = FlowBlock(.repeatEach)
                var xs = args[1]
                if let (h, a) = ExprPrinter.spine(xs), h == "lines", a.count == 1 {
                    xs = a[0]
                    b.eachLine = true
                } else {
                    b.eachLine = false
                }
                guard let s = ExprPrinter.show(xs, 0) else { return nil }
                b.subject = s
            }
            b.name = name
            guard let children = branch(body, keyword: keyword, to: end) else { return nil }
            b.children = children
            return b
        }
    }

    /// An If's test.
    static func condition(_ e: Expr) -> Condition? {
        func code(_ x: Expr) -> String? { ExprPrinter.show(x, 0) }
        func subject(_ x: Expr) -> (String, Bool)? {
            if let (h, a) = ExprPrinter.spine(x), h == "int", a.count == 1, let s = code(a[0]) { return (s, true) }
            guard let s = code(x) else { return nil }
            return (s, false)
        }
        if case let .binary(op, l, r) = e.kind {
            let tests: [String: Condition.Test] = ["=": .equals, "<>": .notEquals, ">": .greater, "<": .less, ">=": .atLeast, "<=": .atMost]
            if let test = tests[op] {
                // trim x = "" is "is empty".
                if op == "=" || op == "<>", case .str("") = r.kind, let (h, a) = ExprPrinter.spine(l), h == "trim", a.count == 1, let s = code(a[0]) {
                    return Condition(subject: s, test: op == "=" ? .isEmpty : .notEmpty)
                }
                guard let (s, asNumber) = subject(l) else { return nil }
                switch r.kind {
                case .str, .interp:
                    guard !test.numeric, let v = Template.of(r) else { break }
                    return Condition(subject: s, test: test, value: v, bare: false, asNumber: asNumber)
                default:
                    guard let v = code(r) else { break }
                    let value: String
                    if case .int = r.kind { value = v } else { value = "{\(v)}" }
                    return Condition(subject: s, test: test, value: value, bare: true, asNumber: asNumber)
                }
            }
        }
        var negated = false
        var x = e
        if let (h, a) = ExprPrinter.spine(e), h == "not", a.count == 1 {
            negated = true
            x = a[0]
        }
        if case let .field(r, "ok") = x.kind, let s = code(r) {
            return Condition(subject: s, test: negated ? .failed : .succeeded)
        }
        if let (h, a) = ExprPrinter.spine(x) {
            switch (h, a.count) {
            case ("contains", 2), ("startsWith", 2), ("endsWith", 2):
                guard h == "contains" || !negated, let v = Template.of(a[0]), let (s, asNumber) = subject(a[1]), !asNumber else { break }
                let test: Condition.Test = h == "contains" ? (negated ? .notContains : .contains) : h == "startsWith" ? .startsWith : .endsWith
                return Condition(subject: s, test: test, value: v)
            case ("isEmpty", 1):
                guard let s = code(a[0]) else { break }
                return Condition(subject: s, test: negated ? .notEmpty : .isEmpty)
            case ("exists", 1):
                guard let v = Template.of(a[0]) else { break }
                return Condition(test: negated ? .notExists : .exists, value: v)
            case ("askYesNo", 1):
                guard !negated, let v = Template.of(a[0]) else { break }
                return Condition(test: .answeredYes, value: v)
            default: break
            }
        }
        if case let .name(n) = x.kind {
            return Condition(subject: n, test: negated ? .isFalse : .isTrue)
        }
        guard let whole = code(e) else { return nil }
        return Condition(subject: whole, test: .code)
    }
}
