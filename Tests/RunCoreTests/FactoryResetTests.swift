import Foundation
@testable import RunCore
import XCTest

/// Factory reset: everything the app keeps that didn't come with it goes to the Trash, once the
/// app has quit; a folder of the person's that holds more than the app's is kept.
final class FactoryResetTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func make(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testEverythingTheAppKeepsGoesToTheTrashOnceItHasQuit() throws {
        let user = root.appendingPathComponent("me", isDirectory: true)
        let home = user.appendingPathComponent("Desktop/TOOL-MAC-RUN", isDirectory: true)
        let support = user.appendingPathComponent("Library/Application Support/ToolMacToolRun", isDirectory: true)
        _ = try make("me/Desktop/TOOL-MAC-RUN/MEMORY/PEOPLE.md")
        _ = try make("me/Desktop/TOOL-MAC-RUN/LIBRARY/groceries.md")
        _ = try make("me/Library/Application Support/ToolMacToolRun/runs.json")
        _ = try make("me/Scripts/hello.sh")
        _ = try make("me/Desktop/other.txt", "the person's own")
        let scripts = user.appendingPathComponent("Scripts", isDirectory: true)
        let plan = FactoryReset.plan(scripts: scripts, home: home, support: support,
                                     shelves: [home.appendingPathComponent("LIBRARY"), home.appendingPathComponent("MEMORY"), home.appendingPathComponent("MIND")], user: user)
        XCTAssertEqual(plan.trash.map(\.lastPathComponent), ["ToolMacToolRun", "TOOL-MAC-RUN", "Scripts"], "the shelves go with TOOL-MAC-RUN")
        XCTAssertEqual(plan.kept, [])

        // As the app runs it, with a process that has already ended standing for the app.
        let trash = user.appendingPathComponent(".Trash", isDirectory: true)
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/bin/sh")
        gone.arguments = ["-c", "exit 0"]
        try gone.run()
        gone.waitUntilExit()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", FactoryReset.script] + FactoryReset.arguments(pid: gone.processIdentifier, trash: trash, app: nil, domain: nil, plan: plan,
                                                                         at: Date(timeIntervalSince1970: 0))
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: home.path))
        XCTAssertFalse(fm.fileExists(atPath: support.path))
        XCTAssertFalse(fm.fileExists(atPath: scripts.path))
        XCTAssertTrue(fm.fileExists(atPath: user.appendingPathComponent("Desktop/other.txt").path), "the person's own things stay")
        let inTrash = try fm.contentsOfDirectory(atPath: trash.path).sorted()
        XCTAssertEqual(inTrash.count, 3)
        XCTAssertTrue(inTrash.allSatisfy { $0.contains("(reset ") }, "\(inTrash)")
        XCTAssertTrue(fm.fileExists(atPath: trash.path + "/" + inTrash.first { $0.hasPrefix("TOOL-MAC-RUN") }! + "/MEMORY/PEOPLE.md"), "kept whole, to be had back")
    }

    /// The library, MEMORY and the mind move from TOOL-MAC-RUN to Storage Spaces' USER space,
    /// once, whole; one already there is left alone; and a factory reset leaves them.
    func testTheShelvesMoveToStorageSpacesOnce() throws {
        let home = root.appendingPathComponent("TOOL-MAC-RUN", isDirectory: true)
        let user = root.appendingPathComponent("STORAGE-SPACES/USER", isDirectory: true)
        _ = try make("TOOL-MAC-RUN/LIBRARY/groceries.md", "- eggs")
        _ = try make("TOOL-MAC-RUN/MEMORY/PEOPLE.md", "# PEOPLE")
        _ = try make("TOOL-MAC-RUN/SYSTEM-DOCS/START-HERE.md")
        // Storage Spaces made the mind there already: it stays, and TOOL-MAC-RUN's with it.
        _ = try make("STORAGE-SPACES/USER/MIND/mind.txt", "| sam | paper")
        _ = try make("TOOL-MAC-RUN/MIND/mind.txt", "| old | mind")
        // …and copied MEMORY in, but for one file: that one comes over; the rest stay as they are there.
        _ = try make("STORAGE-SPACES/USER/MEMORY/PEOPLE.md", "# PEOPLE, edited there")
        _ = try make("TOOL-MAC-RUN/MEMORY/IDEAS.md", "# IDEAS")
        let moved = StorageSpaces.moveIn(from: home, to: user)
        XCTAssertEqual(moved, ["LIBRARY", "MEMORY/IDEAS"])
        XCTAssertEqual(try String(contentsOf: user.appendingPathComponent("MEMORY/PEOPLE.md"), encoding: .utf8), "# PEOPLE, edited there")
        let fm = FileManager.default
        XCTAssertEqual(try String(contentsOf: user.appendingPathComponent("LIBRARY/groceries.md"), encoding: .utf8), "- eggs")
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("LIBRARY").path))
        XCTAssertEqual(try String(contentsOf: user.appendingPathComponent("MIND/mind.txt"), encoding: .utf8), "| sam | paper")
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("MIND/mind.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("SYSTEM-DOCS/START-HERE.md").path), "SYSTEM-DOCS stays the app's")
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("WHERE-THE-LIBRARY-WENT.md").path))
        try FileManager.default.removeItem(at: user.appendingPathComponent("MEMORY/IDEAS.md"))
        XCTAssertEqual(StorageSpaces.moveIn(from: home, to: user), [], "once: what's deleted there stays deleted")
        XCTAssertFalse(Shelf.systemDocs.inStorageSpaces)
        XCTAssertTrue(Shelf.library.inStorageSpaces && Shelf.memory.inStorageSpaces)
        // A factory reset's own shelves are SYSTEM-DOCS alone (worked out without looking at the
        // Desktop: on a Mac, a test reading it waits on a question nobody is there to answer).
        XCTAssertEqual(Shelf.allCases.filter { !$0.inStorageSpaces }, [.systemDocs])
        let plan = FactoryReset.plan(scripts: nil, home: home, support: root.appendingPathComponent("support"), shelves: [], user: root)
        XCTAssertFalse(plan.trash.contains { $0.path.contains("STORAGE-SPACES") }, "\(plan.trash)")
    }

    func testAFolderOfThePersonsIsNeverTakenWhole() {
        let user = URL(fileURLWithPath: "/Users/sam")
        for path in ["/", "/Users", "/Users/sam", "/Users/sam/Documents", "/Users/sam/Desktop", "/Users/sam/Downloads", "/Applications", "/Volumes/Backup"] {
            XCTAssertFalse(FactoryReset.mayRemove(URL(fileURLWithPath: path), user: user), path)
        }
        for path in ["/Users/sam/Scripts", "/Users/sam/Documents/Scripts", "/Volumes/Backup/Scripts"] {
            XCTAssertTrue(FactoryReset.mayRemove(URL(fileURLWithPath: path), user: user), path)
        }
        let kept = FactoryReset.plan(scripts: URL(fileURLWithPath: "/Users/sam/Documents"), home: root, support: root.appendingPathComponent("support"), shelves: [], user: user)
        XCTAssertEqual(kept.kept, ["~/Documents, the scripts folder: it holds more than scripts"])
    }
}
