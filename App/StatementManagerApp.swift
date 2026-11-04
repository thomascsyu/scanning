import SwiftUI
import Darwin
import StatementCore

@main struct StatementManagerApp: App {
    @State private var store: AppStore?
    @State private var startupError: String?
    init() {
        if ProcessInfo.processInfo.arguments.contains("--self-check") {
            do { try runSelfCheck(); exit(0) }
            catch { print("Self-check failed: \(error.localizedDescription)"); exit(1) }
        }
        do { _store = State(initialValue: try AppStore()) }
        catch { _startupError = State(initialValue: error.localizedDescription) }
    }
    var body: some Scene {
        WindowGroup {
            if let store { ContentView(store: store).frame(minWidth: 1100, minHeight: 700) }
            else { ContentUnavailableView("Workspace could not be opened", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError ?? "Unknown error")) .padding(40) }
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Statements…") { store?.openPDFs() }.keyboardShortcut("i").disabled(store?.workspace.accounts.isEmpty != false)
                Button("Import Invoice Register…") { store?.openInvoices() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Export Statement to Excel…") { store?.exportStatementExcel() }.disabled(store?.selectedStatement == nil)
                Button("Export All Transactions to Excel…") { store?.exportAllTransactionsExcel() }
                Button("Export Reviewed Transactions…") { store?.export("transactions") }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Create Backup…") { store?.backup() }
                Button("Restore Backup…") { store?.restore() }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo \(store?.undoHistory.last?.0 ?? "")") { store?.undo() }.keyboardShortcut("z").disabled(store?.undoHistory.isEmpty != false)
                Button("Redo \(store?.redoHistory.last?.0 ?? "")") { store?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(store?.redoHistory.isEmpty != false)
            }
            CommandGroup(replacing: .appSettings) { Button("Workspace Settings…") { store?.showSettings = true }.keyboardShortcut(","); Button("AI Settings…") { store?.showAISettings = true } }
        }
    }
}
