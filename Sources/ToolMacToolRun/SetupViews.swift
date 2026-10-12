import AppKit
import RunCore
import SwiftUI

/// The first thing a grid shows before there's a folder: where the scripts live. One click uses
/// ~/Scripts (made if it isn't there); or pick any folder.
struct FolderSetupView: View {
    @ObservedObject var app: AppModel
    let kind: GridKind
    @State private var examples = true
    @State private var epa = true

    private var suggested: URL { AppModel.suggestedFolder }
    private var suggestedExists: Bool { FileManager.default.fileExists(atPath: suggested.path) }
    private var suggestedCount: Int { Library(root: suggested).scripts().count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Where do your scripts live?")
                .font(.largeTitle.weight(.semibold))
            Text("Pick the folder your scripts are in, or let the app make one. Every script at the top of that folder gets a cell on the Scripts grid. Flows, which compose them, go in a \"composer\" folder inside it (made for you). Nothing else in the folder is touched.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    use(suggested)
                } label: {
                    Label(suggestedExists ? "Use ~/Scripts (\(suggestedCount) script\(suggestedCount == 1 ? "" : "s") there now)" : "Make and Use ~/Scripts",
                          systemImage: "folder.badge.plus")
                        .frame(minWidth: 320)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button {
                    app.chooseFolder()
                    addStarters()
                } label: {
                    Label("Choose Another Folder…", systemImage: "folder")
                        .frame(minWidth: 320)
                }
                Toggle("Add the examples if the folder has no scripts (5 small scripts and 4 flows that use them)", isOn: $examples)
                    .padding(.top, 4)
                Toggle("Add the EPA recipes (connect services, secure a site, onboard and offboard people…), and set EPA up if it isn't yet", isOn: $epa)
            }
            .controlSize(.large)
            Text("You can change the folder any time from the menu bar icon (Change Folder…).")
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func use(_ url: URL) {
        app.setFolder(url)
        addStarters()
    }

    /// The examples (into a folder with no scripts) and the EPA recipes, as ticked.
    private func addStarters() {
        guard let lib = app.library else { return }
        if examples, lib.scripts().isEmpty { GridActions(app: app, kind: kind).addExamples() }
        if epa, !lib.hasEPARecipes { GridActions(app: app, kind: kind).addEPARecipes() }
    }
}

/// Check Setup: the folder, the scripts and flows in it, and the programs they need, each with
/// how to fix it when it's not right. It only looks.
struct DoctorView: View {
    @ObservedObject var app: AppModel
    @State private var lines: [Doctor.Line] = []
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check Setup").font(.title2.weight(.semibold))
                    Text("A look at your folder and the programs your scripts need. It doesn't change anything.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(checking ? "Checking…" : "Check Again") { run() }
                    .disabled(checking)
            }
            .padding(.horizontal, 20)
            .padding(.top, 34)
            .padding(.bottom, 12)
            Divider()
            List(lines) { line in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Theme.symbol(line.status))
                        .foregroundStyle(Theme.color(line.status))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.title).fontWeight(.medium)
                        if let detail = line.detail { Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let fix = line.fix {
                            HStack(spacing: 6) {
                                Text("→ \(fix)").font(.callout.monospaced()).textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fix.replacingOccurrences(of: ", then run it again.", with: ""), forType: .string)
                                } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                    .help("Copy")
                            }
                        }
                        // The fix is a script in the folder: one click runs it (and Check Again shows the result).
                        if let file = line.run, app.library?.script(named: file) != nil {
                            Button("Run \((file as NSString).deletingPathExtension)") { GridActions(app: app, kind: .scripts).runFile(file) }
                                .controlSize(.small)
                                .help("Runs \(file) from your folder: its cell on the Scripts grid shows it going, and Runs has its output")
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            if app.library == nil {
                HStack {
                    Button("Choose Your Scripts Folder…") { app.openGrid(.scripts) }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .padding(16)
            }
        }
        .onAppear(perform: run)
    }

    private func run() {
        checking = true
        let lib = app.library
        Task.detached {
            let result = Doctor.check(lib)
            await MainActor.run {
                lines = result
                checking = false
            }
        }
    }
}
