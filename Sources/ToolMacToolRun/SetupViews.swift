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
            IconTile(symbol: "folder.fill", size: 64)
            Text("Where do your scripts live?")
                .font(.system(size: 34, weight: .bold, design: .rounded))
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
                .buttonStyle(ProminentButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
                Button {
                    app.chooseFolder()
                    addStarters()
                } label: {
                    Label("Choose Another Folder…", systemImage: "folder")
                        .frame(minWidth: 320)
                }
                .buttonStyle(SoftButtonStyle(large: true))
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Add the examples if the folder has no scripts (\(Library.examplesSummary(for: .scripts)) that use them, \(Library.examplesSummary(for: .utilities)) and \(Library.examplesSummary(for: .browser)))", isOn: $examples)
                    Toggle("Add the EPA recipes (connect services, secure a site, onboard and offboard people…), and set EPA up if it isn't yet", isOn: $epa)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(radius: 14, shadow: false)
                .padding(.top, 6)
            }
            Text("You can change the folder any time from the menu bar icon (Change…, beside the folder).")
                .foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Backdrop())
    }

    private func use(_ url: URL) {
        app.setFolder(url)
        addStarters()
    }

    /// The examples (into a folder with no scripts) and the EPA recipes, as ticked.
    private func addStarters() {
        guard let lib = app.library else { return }
        if examples, lib.scripts().isEmpty { GridActions(app: app, kind: kind).addExamples(all: true) }
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
            HStack(spacing: 14) {
                IconTile(symbol: "stethoscope", color: .teal, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Check Setup").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("A look at your folder and the programs your scripts need. It doesn't change anything.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { run() } label: {
                    Label(checking ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(checking)
            }
            .padding(.horizontal, 22)
            .padding(.top, 36)
            .padding(.bottom, 12)
            if !lines.isEmpty {
                HStack(spacing: 8) {
                    tally(.ok, "fine")
                    tally(.warning, "to look at")
                    tally(.problem, "to fix")
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(lines) { line in row(line) }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            }
            if app.library == nil {
                HStack {
                    Button("Choose Your Scripts Folder…") { app.openGrid(.scripts) }
                        .buttonStyle(ProminentButtonStyle())
                    Spacer()
                }
                .padding(16)
            }
        }
        .background(Backdrop())
        .onAppear(perform: run)
    }

    /// How many lines came out this way, when any did.
    @ViewBuilder
    private func tally(_ status: Doctor.Line.Status, _ words: String) -> some View {
        let n = lines.filter { $0.status == status }.count
        if n > 0 { Pill(text: "\(n) \(words)", symbol: Theme.symbol(status), color: Theme.color(status)) }
    }

    private func row(_ line: Doctor.Line) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Theme.symbol(line.status))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.color(line.status))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.color(line.status).opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(line.title).fontWeight(.semibold)
                if let detail = line.detail { Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if let fix = line.fix {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(fix).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer(minLength: 4)
                        CopyButton(help: "Copy the fix", size: 24) { fix.replacingOccurrences(of: ", then run it again.", with: "") }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
                // The fix is a script in the folder: one click runs it (and Check Again shows the result).
                if let file = line.run, app.library?.script(named: file) != nil {
                    Button { GridActions(app: app, kind: .scripts).runFile(file) } label: {
                        Label("Run \((file as NSString).deletingPathExtension)", systemImage: "play.fill")
                    }
                    .buttonStyle(ProminentButtonStyle())
                    .help("Runs \(file) from your folder: its cell on the Scripts grid shows it going, and Runs has its output")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14, shadow: false)
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
