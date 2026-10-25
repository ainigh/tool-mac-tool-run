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
