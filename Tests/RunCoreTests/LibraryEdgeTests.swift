import XCTest
@testable import RunCore

/// The folder's edges: Windows line ends, byte-order marks, names that would hide a file, and
/// languages told apart from what's in a file.
final class LibraryEdgeTests: XCTestCase {
    func testSummaryWithWindowsLineEndsAndAByteOrderMark() {
        XCTAssertEqual(Library.summary("#!/bin/bash\r\n# Windows summary\r\necho hi\r\n"), "Windows summary")
        XCTAssertEqual(Library.summary("\u{FEFF}# Marked summary\n"), "Marked summary")
        XCTAssertEqual(Library.summary("#!/bin/bash\n# Plain\n"), "Plain")
    }

    func testANewFileIsNeverHidden() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("library-edge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = Library(root: dir)
        XCTAssertEqual(try lib.newScript(name: ".secret", language: .bash).lastPathComponent, "secret.sh")
        XCTAssertEqual(try lib.newScript(name: "..", language: .bash).lastPathComponent, "untitled.sh")
        XCTAssertEqual(Set(lib.scripts().map(\.id)), ["secret.sh", "untitled.sh"])
        XCTAssertEqual(Library.fileName(" a/b "), "a-b")
    }

    func testSniffingTellsSwiftAndJavaScriptFromPython() {
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool", contents: "import Foundation\nprint(1)\n"), .swift)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool", contents: "import fs from \"fs\";\nconsole.log(1)\n"), .node)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool", contents: "import sys\nprint(sys.argv)\n"), .python)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool", contents: "import os, sys\n"), .python)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool", contents: "import numpy as np\n"), .python)
        XCTAssertEqual(ScriptLanguage.detect(fileName: "tool", contents: "from os import path\n"), .python)
    }

    func testEnvSplitStringNamesItsProgram() {
        let s = Shebang.parse("#!/usr/bin/env --split-string=python3 -u\n")
        XCTAssertEqual(s?.program, "python3")
        XCTAssertEqual(ScriptLanguage.detect(fileName: "x", contents: "#!/usr/bin/env --split-string=python3 -u\n"), .python)
        XCTAssertEqual(Shebang.parse("#!/usr/bin/env -S python3 -u\n")?.program, "python3")
    }
}
