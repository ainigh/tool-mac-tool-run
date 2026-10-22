import Foundation
@testable import RunCore
import XCTest

/// Automation: the fixed tags, when a schedule next runs, what sets a trigger off, and how an
/// item's automation is kept.
final class AutomationTests: XCTestCase {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testTagsAreNamedAsPeopleAndAppsWriteThem() {
        XCTAssertEqual(AutomationTag.named("every-morning"), .everyMorning)
        XCTAssertEqual(AutomationTag.named("every morning"), .everyMorning)
        XCTAssertEqual(AutomationTag.named("Every Morning "), .everyMorning)
        XCTAssertEqual(AutomationTag.named("every_10_minutes"), .every10Minutes)
        XCTAssertEqual(AutomationTag.named("hourly"), .everyHour)
        XCTAssertEqual(AutomationTag.named("every 1 hour"), .everyHour)
        XCTAssertEqual(AutomationTag.named("daily"), .everyDay)
        XCTAssertEqual(AutomationTag.named("when api call is made"), .whenAPICalled)
        XCTAssertEqual(AutomationTag.named("when any item runs"), .whenAnythingRuns)
        XCTAssertEqual(AutomationTag.named("after"), .afterItem)
        XCTAssertNil(AutomationTag.named("every fortnight"))
        // Every tag names itself, and the names are what the API lists.
        for tag in AutomationTag.allCases {
            XCTAssertEqual(AutomationTag.named(tag.rawValue), tag)
            XCTAssertEqual(AutomationTag.named(tag.title), tag, tag.title)
            XCTAssertFalse(tag.about.isEmpty)
        }
        XCTAssertEqual(AutomationTag.schedules.count + AutomationTag.triggers.count, AutomationTag.allCases.count)
        XCTAssertEqual(AutomationTag.allCases.first, .everyMinute)
    }

    func testASchedulesNextTime() {
        let last = date("2026-10-22 10:17")
        XCTAssertEqual(AutomationTag.everyMinute.next(after: last, calendar: calendar), date("2026-10-22 10:18"))
        XCTAssertEqual(AutomationTag.every10Minutes.next(after: last, calendar: calendar), date("2026-10-22 10:27"))
        XCTAssertEqual(AutomationTag.everyHour.next(after: last, calendar: calendar), date("2026-10-22 11:17"))
        // On the clock: the next time of day after the last.
        XCTAssertEqual(AutomationTag.everyMorning.next(after: last, calendar: calendar), date("2026-10-23 07:00"))
        XCTAssertEqual(AutomationTag.everyAfternoon.next(after: last, calendar: calendar), date("2026-10-22 13:00"))
        XCTAssertEqual(AutomationTag.everyEvening.next(after: last, calendar: calendar), date("2026-10-22 19:00"))
        XCTAssertEqual(AutomationTag.everyDay.next(after: date("2026-10-22 08:59"), calendar: calendar), date("2026-10-22 09:00"))
        XCTAssertEqual(AutomationTag.everyDay.next(after: date("2026-10-22 09:00"), calendar: calendar), date("2026-10-23 09:00"))
        // 2026-10-22 is a Thursday: the next Monday.
        XCTAssertEqual(AutomationTag.everyWeek.next(after: last, calendar: calendar), date("2026-10-26 09:00"))
        XCTAssertEqual(AutomationTag.everyMonth.next(after: last, calendar: calendar), date("2026-11-01 09:00"))
        // A trigger has no time.
        XCTAssertNil(AutomationTag.whenAPICalled.next(after: last, calendar: calendar))
    }

    func testTheLogCountsAJustTaggedScheduleFromNow() {
        var log = AutomationLog()
        let now = date("2026-10-22 10:00")
        let a = Automation(tags: [.every10Minutes, .everyEvening])
        let next = log.next(for: "x.sh", a, now: now, calendar: calendar)
        XCTAssertEqual(next?.tag, .every10Minutes)
        XCTAssertEqual(next?.at, date("2026-10-22 10:10"))
        // Now it's remembered: asked again later, the same time.
        XCTAssertEqual(log.next(for: "x.sh", a, now: date("2026-10-22 10:05"), calendar: calendar)?.at, date("2026-10-22 10:10"))
        // Whichever schedule comes first: 18:50 before this evening's 19:00, then 19:00 before 19:05.
        log.mark("x.sh", .every10Minutes, at: date("2026-10-22 18:40"))
        XCTAssertEqual(log.next(for: "x.sh", a, now: date("2026-10-22 18:45"), calendar: calendar)?.tag, .every10Minutes)
        log.mark("x.sh", .every10Minutes, at: date("2026-10-22 18:55"))
        let evening = log.next(for: "x.sh", a, now: date("2026-10-22 18:56"), calendar: calendar)
        XCTAssertEqual(evening?.tag, .everyEvening)
        XCTAssertEqual(evening?.at, date("2026-10-22 19:00"))
        XCTAssertNil(log.next(for: "y.sh", Automation(tags: [.whenAnythingRuns]), now: now, calendar: calendar))
        log.rename("x.sh", to: "z.sh")
        XCTAssertNil(log.last("x.sh", .every10Minutes))
        XCTAssertNotNil(log.last("z.sh", .every10Minutes))
        let back = try! JSONDecoder().decode(AutomationLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(back, log)
    }

    func testWhatSetsATriggerOff() {
        func run(_ kind: RunRecord.Kind, _ file: String, by: String? = nil) -> RunRecord {
            var r = RunRecord(kind: kind, name: file, file: file, command: "x")
            r.requestedBy = by
            return r
        }
        let anything = Automation(tags: [.whenAnythingRuns])
        XCTAssertEqual(anything.trigger(for: run(.script, "a.sh"), grid: .scripts), .whenAnythingRuns)
        // A run the automation started never sets off another.
        XCTAssertNil(anything.trigger(for: run(.script, "a.sh", by: "Automation: every minute"), grid: .scripts))
        let api = Automation(tags: [.whenAPICalled])
        XCTAssertEqual(api.trigger(for: run(.flow, "m.flow", by: "curl, on this Mac"), grid: .composer), .whenAPICalled)
        XCTAssertNil(api.trigger(for: run(.flow, "m.flow"), grid: .composer))
        let scripts = Automation(tags: [.whenScriptRuns, .whenUtilityRuns])
        XCTAssertEqual(scripts.trigger(for: run(.script, "a.sh"), grid: .scripts), .whenScriptRuns)
        XCTAssertEqual(scripts.trigger(for: run(.script, "utilities/s.sh"), grid: .utilities), .whenUtilityRuns)
        XCTAssertNil(scripts.trigger(for: run(.script, "browser/b.sh"), grid: .browser))
        XCTAssertNil(scripts.trigger(for: run(.flow, "m.flow"), grid: .composer))
        let after = Automation(tags: [.afterItem], after: ["backup.sh"])
        XCTAssertEqual(after.trigger(for: run(.script, "backup.sh"), grid: .scripts), .afterItem)
        XCTAssertNil(after.trigger(for: run(.script, "other.sh"), grid: .scripts))
        // A step of a flow isn't a run of its own.
        var step = run(.step, "backup.sh")
        step.parent = UUID()
        XCTAssertNil(after.trigger(for: step, grid: .scripts))
    }

    func testAnItemsAutomationIsKeptWithItsGridAndReadsTolerantly() throws {
        var s = GridSettings()
        s.setAutomation(Automation(tags: [.whenAPICalled, .everyMorning], once: true), for: "hello.sh")
        XCTAssertEqual(s.automation(for: "hello.sh").tags, [.everyMorning, .whenAPICalled], "in the table's order, whatever order they were given in")
        XCTAssertEqual(s.automation(for: "hello.sh").summary, "every morning, when the API is called · once")
        XCTAssertEqual(s.automation(for: "nope.sh"), Automation())
        let back = try JSONDecoder().decode(GridSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.automation, s.automation)
        // Taken off: gone from the settings.
        s.setAutomation(Automation(), for: "hello.sh")
        XCTAssertNil(s.automation["hello.sh"])
        // Earlier settings, and a tag this version doesn't know.
        let old = try JSONDecoder().decode(GridSettings.self, from: Data(#"{"cells": 9}"#.utf8))
        XCTAssertEqual(old.automation, [:])
        let odd = try JSONDecoder().decode(GridSettings.self, from: Data(#"{"automation": {"a.sh": {"tags": ["every-morning", "every-blue-moon"], "once": true}, "b.sh": {"tags": ["every-blue-moon"]}}}"#.utf8))
        XCTAssertEqual(odd.automation["a.sh"], Automation(tags: [.everyMorning], once: true))
        XCTAssertNil(odd.automation["b.sh"], "nothing left that this version knows: not automated")
        var a = Automation(tags: [.everyDay])
        a.set(.everyDay, on: false)
        a.set(.afterItem, on: true)
        a.after = ["backup.sh"]
        XCTAssertEqual(a.summary, "after backup.sh")
        XCTAssertEqual(Automation().summary, "not automated")
    }

    func testAnAutomatedRunSaysSo() {
        var r = RunRecord(kind: .script, name: "a.sh", file: "a.sh", command: "x")
        XCTAssertFalse(r.isAutomated)
        r.requestedBy = "Automation: every morning"
        XCTAssertTrue(r.isAutomated)
        r.requestedBy = "curl, on this Mac"
        XCTAssertFalse(r.isAutomated)
    }
}

/// Why a question is asked: the `Why:` line under an `Input:` line, the `…Because` functions, and
/// the block editor's Why field.
final class WhyTests: XCTestCase {
    func testAWhyLineGoesWithTheInputAboveIt() {
        let script = """
        #!/bin/bash
        # Asks Google
        #
        # Input: What should Google be asked?
        # Why: It's typed into Google's search box as is
        # Input (optional): A language
        # Input text: The page
        # Why: Only its text is read, not its links
        """
        let inputs = ScriptInput.declared(in: script)
        XCTAssertEqual(inputs.map(\.prompt), ["What should Google be asked?", "A language", "The page"])
        XCTAssertEqual(inputs.map(\.why), ["It's typed into Google's search box as is", nil, "Only its text is read, not its links"])
        // A Why with no Input above it is nothing; and never the summary.
        XCTAssertEqual(ScriptInput.declared(in: "# Why: lost\n# Input: A\n"), [ScriptInput(prompt: "A")])
        XCTAssertEqual(Library.summary("#!/bin/bash\n# Input: A name\n# Why: it's said\n# Says hello\n"), "Says hello")
        XCTAssertEqual(ScriptInput.parseWhy("why: "), nil)
        XCTAssertEqual(ScriptInput.parseWhy("WHY : because"), "because")
    }

    func testTheExamplesSayWhy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("why-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let lib = Library(root: folder)
        try lib.addExamples(for: .utilities)
        let alarm = try XCTUnwrap(lib.items(.utilities).first { $0.id == "utilities/alarm.sh" })
        XCTAssertEqual(alarm.inputs.count, 2)
        XCTAssertNotNil(alarm.inputs[0].why)
        XCTAssertTrue(alarm.inputs[1].optional)
        XCTAssertTrue(alarm.summary?.hasPrefix("Sets an alarm") == true)
        let copy = try XCTUnwrap(lib.items(.utilities).first { $0.id == "utilities/copy-to-clipboard.sh" })
        XCTAssertEqual(copy.inputs.map(\.optional), [false])
        XCTAssertNotNil(copy.inputs[0].why)
    }

    func testTheBecauseFunctionsCarryTheWhy() throws {
        let host = FakeHost()
        host.answers = [.yes, .no, .text("Ada"), .text("large")]
        try Flow.run("""
        confirmBecause "Go on?" "It deletes the old ones"
        print (askYesNoBecause "Upload?" "It takes a minute")
        let who = askBecause "Who?" "It goes on the letter"
        let size = chooseBecause "Size?" "Large costs more" ["small"; "large"]
        print $"{who} {size}"
        """, host: host, args: [])
        XCTAssertEqual(host.said, ["false", "Ada large"])
        XCTAssertEqual(host.asked.map(\.kind), [.proceed, .yesNo, .text, .choice(["small", "large"])])
        XCTAssertEqual(host.asked.map(\.why), ["It deletes the old ones", "It takes a minute", "It goes on the letter", "Large costs more"])
        XCTAssertEqual(host.asked.map(\.prompt), ["Go on?", "Upload?", "Who?", "Size?"])
        // An empty why is no why.
        XCTAssertNil(FlowQuestion(kind: .proceed, prompt: "x", line: 1, why: "  ").why)
        let types = Dictionary(try Flow.check("let f = chooseBecause").bindings.map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(types["f"], "string -> string -> string list -> string")
    }

    func testTheWhyFieldIsWrittenAsBecauseAndReadBack() throws {
        func block(_ type: BlockType, _ change: (inout FlowBlock) -> Void) -> FlowBlock {
            var b = FlowBlock(type)
            change(&b)
            return b
        }
        let doc = FlowDocument(summary: "Why", blocks: [
            block(.confirm) { $0.text = "Delete them?"; $0.why = "They're 30 days old" },
            block(.ask) { $0.text = "Who?"; $0.why = "It goes on the letter"; $0.name = "who" },
            block(.askYesNo) { $0.text = "Upload?"; $0.why = "About a minute"; $0.name = "up" },
            block(.choose) { $0.text = "Size?"; $0.why = "Large costs {who}"; $0.args = ["small", "large"]; $0.name = "size" },
            block(.confirm) { $0.text = "No why" },
        ])
        let text = doc.written().text
        XCTAssertTrue(text.contains("confirmBecause \"Delete them?\" \"They're 30 days old\""), text)
        XCTAssertTrue(text.contains("let who = askBecause \"Who?\" \"It goes on the letter\""), text)
        XCTAssertTrue(text.contains("let up = askYesNoBecause \"Upload?\" \"About a minute\""), text)
        XCTAssertTrue(text.contains("chooseBecause \"Size?\" $\"Large costs {who}\" [\"small\"; \"large\"]"), text)
        XCTAssertTrue(text.contains("\nconfirm \"No why\""), text)
        XCTAssertNoThrow(try Flow.check(text, scripts: []))
        let back = FlowDocument.read(text)
        XCTAssertEqual(back.blocks.map(\.type), doc.blocks.map(\.type))
        XCTAssertEqual(back.blocks.map(\.why), doc.blocks.map(\.why))
        XCTAssertEqual(back.blocks.map(\.text), doc.blocks.map(\.text))
        XCTAssertEqual(back.written().text, text)
    }
}
