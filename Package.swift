// swift-tools-version:5.9
import PackageDescription

// RunCore is the logic (finding scripts, telling their language, running them, the Flow language
// that composes them): Foundation only, so it's tested on any machine (swift test). `flow` runs
// and checks .flow files from a terminal, on a Mac or Linux.
var targets: [Target] = [
    .target(name: "RunCore"),
    .executableTarget(name: "flow", dependencies: ["RunCore"]),
    .testTarget(name: "RunCoreTests", dependencies: ["RunCore"]),
]
#if os(macOS)
// The menu bar app: SwiftUI + AppKit, so only on the Mac.
targets.append(.executableTarget(name: "ToolMacToolRun", dependencies: ["RunCore"]))
#endif

let package = Package(name: "ToolMacToolRun", platforms: [.macOS(.v14)], targets: targets)
