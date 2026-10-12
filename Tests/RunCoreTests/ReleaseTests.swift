import XCTest
@testable import RunCore

final class ReleaseTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertLessThan(ToolVersion("0.1.9")!, ToolVersion("v0.1.12")!)
        XCTAssertEqual(ToolVersion("1.0")!, ToolVersion("1.0.0")!)
        XCTAssertNil(ToolVersion("0.1-abc"))
        XCTAssertNil(ToolVersion(""))
    }

    let releaseJSON = #"""
    {"tag_name":"v0.1.70","target_commitish":"abcdef1234567890","html_url":"https://x",
     "assets":[{"name":"ToolMacToolRun.zip","browser_download_url":"https://example.com/ToolMacToolRun.zip"}]}
    """#
    let commitJSON = #"{"sha":"abcdef1234567890","commit":{"message":"Fix notify\n\nDetails"}}"#

    func testDecodesGitHubPayloads() throws {
        let release = try GitHubRelease.decode(Data(releaseJSON.utf8))
        XCTAssertEqual(release.version, ToolVersion("0.1.70"))
        XCTAssertNotNil(release.asset(named: "ToolMacToolRun.zip"))
        let commit = try GitHubCommit.decode(Data(commitJSON.utf8))
        XCTAssertEqual(commit.short, "abcdef1")
        XCTAssertEqual(commit.title, "Fix notify")
    }

    func testUpdatePlan() throws {
        let release = try GitHubRelease.decode(Data(releaseJSON.utf8))
        let head = try GitHubCommit.decode(Data(commitJSON.utf8))
        let zip = "ToolMacToolRun.zip"
        XCTAssertEqual(UpdatePlan.decide(head: head, installedCommit: "abcdef1234567890", latestRelease: release, assetName: zip), .upToDate)
        XCTAssertEqual(UpdatePlan.decide(head: head, installedCommit: "abcdef1", latestRelease: release, assetName: zip), .upToDate)
        XCTAssertEqual(UpdatePlan.decide(head: head, installedCommit: "0000000", latestRelease: release, assetName: zip), .prebuilt(head, release))
        let newer = GitHubCommit(sha: "ffff", message: "newer")
        XCTAssertEqual(UpdatePlan.decide(head: newer, installedCommit: "abcdef1", latestRelease: release, assetName: zip), .buildHere(newer))
        XCTAssertEqual(UpdatePlan.decide(head: head, installedCommit: nil, latestRelease: nil, assetName: zip), .buildHere(head))
        // "unknown" (built outside git) is never taken as up to date.
        XCTAssertEqual(UpdatePlan.decide(head: head, installedCommit: "unknown", latestRelease: release, assetName: zip), .prebuilt(head, release))
        XCTAssertEqual(UpdatePlan.prebuilt(head, release).commit, head)
        XCTAssertEqual(UpdatePlan.buildHere(newer).commit, newer)
        XCTAssertNil(UpdatePlan.upToDate.commit)
        XCTAssertEqual(UpdatePlan.prebuilt(head, release).title, "Update to v0.1.70: Fix notify")
    }

    func testSwiftVersionParsing() {
        let out = "swift-driver version: 1.90.11.1 Apple Swift version 5.10 (swiftlang-5.10.0.13 clang-1500.3.9.4)\nTarget: arm64-apple-macosx14.0"
        XCTAssertEqual(SwiftToolchain.version(in: out), ToolVersion("5.10"))
        XCTAssertTrue(SwiftToolchain.isNewEnough(out))
        XCTAssertFalse(SwiftToolchain.isNewEnough("Apple Swift version 5.8.1 (swiftlang-5.8.0.124.5)"))
        XCTAssertTrue(SwiftToolchain.isNewEnough("Swift version 6.0.3 (swift-6.0.3-RELEASE)"))
        XCTAssertFalse(SwiftToolchain.isNewEnough("command not found"))
    }
}
