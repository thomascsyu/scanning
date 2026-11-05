import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import StatementCore

@MainActor @Observable final class AppStore {
    var workspace: Workspace
    var error: String?
    var notice: String?
    var busy = false
    var section: SidebarSection = .statements
    var selectedStatement: UUID?
    var selectedStatementEntry: UUID?
    var selectedTransactionEntry: UUID?
    var selectedInvoice: UUID?
    var importURLs: [URL] = []
    var showPDFImport = false
    var forceOCRForImport = false
    private var checkedEmptyImports = false
    var showInvoiceImport = false
    var invoiceURL: URL?
    var showSettings = false
    var showAISettings = false
    var ai = AISettings()
    var editingEntry: Entry?
    /// Passwords typed during import, keyed by PDF hash. Memory only, never saved, so protected originals can be previewed this session.
    var pdfPasswords: [String: String] = [:]
    var undoHistory: [(String, Workspace)] = []
    var redoHistory: [(String, Workspace)] = []
    let repository: LedgerRepository
    let documents: URL
    init() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--demo") ? "StatementManagerDemo" : "StatementManager", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        documents = support.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        repository = try LedgerRepository(url: support.appendingPathComponent("Workspace.store"))
        workspace = try repository.load()
        if ProcessInfo.processInfo.arguments.contains("--demo") && workspace.businessName.isEmpty { workspace = try DemoWorkspace.create(documents: documents); try repository.save(workspace) }
        selectedStatement = workspace.statements.first?.id
        // Rolled-back or replaced statements keep their PDF for Undo during a session. Undo history is not kept
        // across launches, so those copies are no longer needed and are deleted rather than kept indefinitely.
        OriginalsStore.removeUnreferenced(in: documents, referenced: Set(workspace.statements.map(\.storedFilename)))
    }
    func change(_ label: String, _ action: (inout Workspace) throws -> Void) {
        do {
            let old = workspace; var next = old; try action(&next); next.audit.append(AuditRecord(label))
            // The whole workspace is rewritten on each save; keep the activity log bounded.
            if next.audit.count > Self.auditLimit { next.audit.removeFirst(next.audit.count - Self.auditLimit) }
            try repository.save(next); workspace = next
            undoHistory.append((label, old)); if undoHistory.count > 30 { undoHistory.removeFirst() }; redoHistory.removeAll()
        } catch { self.error = error.localizedDescription }
    }
    /// Fill in references and a suggested type for unclassified rows. Unlike applyRules, never resets categories
    /// or rule results, so running it at launch cannot undo the user's unreviewed work.
    func organizeTransactions() {
        var candidate = workspace
        for i in candidate.entries.indices where !candidate.entries[i].reviewed && !candidate.entries[i].manuallyEdited {
            candidate.entries[i].extractReferences()
            if candidate.entries[i].type == .unknown, candidate.entries[i].customType == nil, candidate.entries[i].ruleID == nil {
                candidate.entries[i].type = candidate.entries[i].suggestedType(incoming: candidate.incoming(candidate.entries[i]))
            }
        }
        guard candidate.entries != workspace.entries else { return }
        change("Organize transaction types and references") { $0.entries = candidate.entries }
    }
    func undo() {
        guard let (label, old) = undoHistory.last else { return }
        do { var restored = old; restored.audit = workspace.audit + [AuditRecord("Undo: " + label)]; try repository.save(restored); redoHistory.append((label, workspace)); workspace = restored; undoHistory.removeLast() } catch { self.error = error.localizedDescription }
    }
    func redo() {
        guard let (label, next) = redoHistory.last else { return }
        do { var restored = next; restored.audit = workspace.audit + [AuditRecord("Redo: " + label)]; try repository.save(restored); undoHistory.append((label, workspace)); workspace = restored; redoHistory.removeLast() } catch { self.error = error.localizedDescription }
    }
    static let auditLimit = 5_000
    static let revisionsPerEntry = 20
    func pdfURL(_ statement: Statement) -> URL { documents.appendingPathComponent(statement.storedFilename) }
    func openPDFs() {
        guard !workspace.accounts.isEmpty else { showSettings = true; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { enqueue(panel.urls) }
    }
    func enqueue(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return }
        if showPDFImport { error = "Finish the current import before adding more files."; return }
        guard !workspace.accounts.isEmpty else { showSettings = true; return }
        importURLs = pdfs; forceOCRForImport = false; showPDFImport = true
    }
    func openInvoices() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, UTType(filenameExtension: "xlsx")!]
        if panel.runModal() == .OK { invoiceURL = panel.url; showInvoiceImport = true }
    }
    func export(_ kind: String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "\(kind)-\(Day.today).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = kind == "transactions" ? Exports.transactions(workspace) : kind == "invoices" ? Exports.invoices(workspace) : Exports.allocations(workspace)
        do { try ("\u{FEFF}" + content).write(to: url, atomically: true, encoding: .utf8); notice = "Exported \(kind)." } catch { self.error = error.localizedDescription }
    }
    func exportStatementExcel(statementID: UUID? = nil) {
        guard let id = statementID ?? selectedStatement, let statement = workspace.statements.first(where: { $0.id == id }) else {
            error = "Select a statement to export."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx")!]
        panel.nameFieldStringValue = Exports.suggestedStatementFilename(statement)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exports.statement(workspace, statementID: id).write(to: url)
            let count = workspace.entries.filter { $0.statementID == id }.count
            notice = "Exported \(count) transactions to Excel."
        } catch { self.error = error.localizedDescription }
    }
    func exportAllTransactionsExcel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Each bank account and credit card gets its own folder, inside Bank statements or Credit card statements."
        guard panel.runModal() == .OK, let root = panel.url else { return }
        do {
            let names = Exports.accountFolderNames(workspace)
            var accountsExported = 0, rows = 0
            for folder in StatementFolder.allCases {
                for account in workspace.accounts(in: folder) {
                    let count = workspace.entries.filter { $0.accountID == account.id }.count
                    guard count > 0, let name = names[account.id] else { continue }
                    let directory = root.appendingPathComponent(folder.rawValue, isDirectory: true).appendingPathComponent(name, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    // Never overwrite an earlier export from the same day.
                    let file = Self.uniqueFile(in: directory, filename: Exports.suggestedAllTransactionsFilename())
                    try Exports.allTransactions(workspace, accountID: account.id).write(to: file)
                    accountsExported += 1; rows += count
                }
            }
            notice = accountsExported == 0 ? "No transactions to export." : "Exported \(rows) transactions into \(accountsExported) account folder\(accountsExported == 1 ? "" : "s")."
        } catch { self.error = error.localizedDescription }
    }
    static func uniqueFile(in directory: URL, filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension, ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename), n = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = directory.appendingPathComponent("\(base) (\(n)).\(ext)"); n += 1 }
        return candidate
    }
    func backup() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.message = "Choose a secure destination. Backups contain financial data; use an encrypted disk."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let destination = url.appendingPathComponent("StatementManager-\(Day.today)-\(UUID().uuidString.prefix(8)).hkledger")
            try WorkspaceBackup.write(workspace, documents: documents, destination: destination); notice = "Backup created with originals and invoice allocations."
        } catch { self.error = error.localizedDescription }
    }
    func restore() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.message = "Select a .hkledger backup folder."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let next = try WorkspaceBackup.read(source)
            let alert = NSAlert(); alert.messageText = "Replace the current workspace?"; alert.informativeText = "The selected backup will replace all current records. You can undo this replacement until you quit; the replaced PDFs are deleted the next time the app opens."; alert.addButton(withTitle: "Restore backup"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // Remap filenames so restoring cannot overwrite originals needed by Undo.
            var restored = next, copied: [URL] = []
            // A failed restore must not leave unreferenced copies of the originals behind.
            func discardCopies() { for url in copied { try? FileManager.default.removeItem(at: url) } }
            do {
                for index in restored.statements.indices {
                    let old = restored.statements[index].storedFilename
                    let destination = documents.appendingPathComponent(UUID().uuidString + ".pdf")
                    try FileManager.default.copyItem(at: source.appendingPathComponent("Originals").appendingPathComponent(old), to: destination)
                    copied.append(destination)
                    restored.statements[index].storedFilename = destination.lastPathComponent
                }
            } catch { discardCopies(); throw error }
            self.error = nil
            change("Restore backup") { $0 = restored }
            if self.error != nil { discardCopies() }
        } catch { self.error = error.localizedDescription }
    }
    func removeStatement(_ statement: Statement) {
        let alert = NSAlert(); alert.messageText = "Roll back this statement import?"; alert.informativeText = "Its transactions and payment allocations will be removed. The original PDF is kept until you quit, so you can Undo; it is deleted the next time the app opens. Invoices remain in the workspace."; alert.addButton(withTitle: "Roll back import"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        change("Roll back statement import") { $0.removeStatement(statement.id) }; selectedStatement = nil; selectedStatementEntry = nil
    }
    func applyRulesInBackground() {
        let snapshot = workspace
        busy = true
        Task {
            defer { busy = false }
            do {
                let next = try await Task.detached(priority: .userInitiated) {
                    var w = snapshot
                    w.applyRules()
                    try w.validate()
                    return w
                }.value
                // If the user changed anything meanwhile, apply rules to the current state so that edit is kept.
                if workspace == snapshot { change("Apply categorization rules") { $0 = next } }
                else { change("Apply categorization rules") { $0.applyRules() } }
            } catch { self.error = error.localizedDescription }
        }
    }
    func saveEntry(_ value: Entry) {
        change("Edit transaction") { state in
            var entry = value; entry.manuallyEdited = true; entry.ruleID = nil
            if let i = state.entries.firstIndex(where: { $0.id == entry.id }) {
                state.revisions.append(EntryRevision(previous: state.entries[i])); state.entries[i] = entry
                // Keep the most recent corrections for each transaction; older history is dropped to bound the workspace.
                let mine = state.revisions.indices.filter { state.revisions[$0].previous.id == entry.id }
                if mine.count > Self.revisionsPerEntry { let drop = Set(mine.prefix(mine.count - Self.revisionsPerEntry)); state.revisions = state.revisions.enumerated().filter { !drop.contains($0.offset) }.map(\.element) }
            } else { state.entries.append(entry) }
            if let i = state.statements.firstIndex(where: { $0.id == entry.statementID }) { state.statements[i].reconciled = false }
            // A corrected date, amount or description can resolve a possible duplicate elsewhere.
            state.flagDuplicates(markNew: false)
        }
    }
    func reextract(_ statement: Statement, forceOCR: Bool = false) {
        importURLs = [pdfURL(statement)]; forceOCRForImport = forceOCR; showPDFImport = true
    }
    func recoverEmptyImports() async {
        guard !checkedEmptyImports else { return }; checkedEmptyImports = true
        let empty = workspace.statements.filter { statement in !workspace.entries.contains { $0.statementID == statement.id } }
        guard !empty.isEmpty else { return }
        busy = true
        defer { busy = false }
        var failures: [String] = []
        for statement in empty {
            let url = pdfURL(statement)
            let label = statement.filename
            do {
                let pdf = try await Task.detached(priority: .utility) { try PDFExtractor.read(url: url) }.value
                guard workspace.statements.first(where: { $0.id == statement.id }) != nil else { continue }
                let snapshot = workspace
                let recovered = try await Task.detached(priority: .userInitiated) {
                    var candidate = snapshot
                    guard try candidate.recoverEmptyImport(statementID: statement.id, pdf: pdf) else { return nil as Workspace? }
                    return candidate
                }.value
                if var candidate = recovered {
                    if workspace != snapshot {
                        // Something changed while recovering; redo it on the current state so no edit is overwritten.
                        var current = workspace
                        guard try current.recoverEmptyImport(statementID: statement.id, pdf: pdf) else { continue }
                        candidate = current
                    }
                    change("Recover empty PDF import") { $0 = candidate }
                    if error == nil {
                        selectedStatement = statement.id
                        notice = "Recovered \(candidate.entries.filter { $0.statementID == statement.id }.count) transactions from your PDF. The count and totals match; please review the table."
                    }
                }
            } catch PDFImportError.password {
                failures.append("\(label): PDF needs a password. Open the statement and choose Read PDF with the password.")
            } catch {
                failures.append("\(label): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            let summary = failures.prefix(3).joined(separator: " ")
            let extra = failures.count > 3 ? " (\(failures.count - 3) more)" : ""
            if notice == nil {
                notice = "Could not auto-recover some empty imports. \(summary)\(extra)"
            } else {
                notice = notice! + " Some empty imports could not be recovered automatically."
            }
        }
    }
    func newEntry(statement: Statement) {
        editingEntry = Entry(statementID: statement.id, accountID: statement.accountID, date: statement.periodEnd.isEmpty ? Day.today : statement.periodEnd, amount: 0, description: "")
    }
}
enum SidebarSection: String, CaseIterable, Identifiable {
    case statements = "Statements", transactions = "Transactions", invoices = "Invoices", rules = "Rules", reports = "Reports"
    var id: String { rawValue }
    var icon: String { switch self { case .statements: "doc.text"; case .transactions: "list.bullet.rectangle"; case .invoices: "doc.text.magnifyingglass"; case .rules: "slider.horizontal.3"; case .reports: "chart.bar.xaxis" } }
}
