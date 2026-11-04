import SwiftUI
import StatementCore

struct PDFImportView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var accountID: UUID?
    @State private var periodEnd = Day.today
    @State private var periodStart = ""
    @State private var password = ""
    @State private var forceOCR = false
    @State private var extracted: ExtractedPDF?
    @State private var busy = false
    @State private var message: String?
    @State private var replaceExisting = false
    @State private var allowEmptyImport = false
    @State private var draftID = UUID()
    @State private var parsed: ParseResult?
    @State private var reparseTask: Task<Void, Never>?
    var url: URL? { store.importURLs.indices.contains(index) ? store.importURLs[index] : nil }
    var existing: Statement? { guard let extracted else { return nil }; return store.workspace.statements.first { $0.hash == extracted.hash } }
    var account: Account? { store.workspace.accounts.first { $0.id == accountID } }
    var needsReplacementConfirmation: Bool { guard let existing else { return false }; return store.workspace.entries.contains { $0.statementID == existing.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import statement \(index + 1) of \(store.importURLs.count)").font(.title2.bold())
            Text(url?.lastPathComponent ?? "").foregroundStyle(.secondary)
            Text("Confirm the account and statement dates. Every extracted transaction starts in review.").font(.callout)
            Picker("Account", selection: $accountID) { Text("Choose an account").tag(nil as UUID?); ForEach(store.workspace.accounts) { Text("\($0.name) · \($0.kind.rawValue)").tag(Optional($0.id)) } }
            HStack { TextField("Period start (YYYY-MM-DD, optional)", text: $periodStart); TextField("Period end (YYYY-MM-DD)", text: $periodEnd) }
            HStack { SecureField("PDF password, if required", text: $password); Toggle("Force OCR", isOn: $forceOCR); Button(busy ? "Reading…" : "Read PDF") { read() }.disabled(busy) }
            if busy { ProgressView("Reading locally on your Mac…") }
            if let message { Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            if let extracted {
                Label("Detected: \(extracted.bank.rawValue)", systemImage: "doc.text.magnifyingglass")
                if needsReplacementConfirmation {
                    Text("This PDF has already been imported. Skip it, or explicitly replace its staged transactions after OCR. Replacement removes corrections; reverse any invoice allocations first.").font(.callout).foregroundStyle(.orange)
                    Toggle("Replace existing transactions with this extraction", isOn: $replaceExisting)
                }
                if let parsed {
                    Text("\(parsed.entries.count) candidate transactions").font(.headline)
                    if parsed.entries.isEmpty {
                        Text("No transaction rows could be extracted. The PDF has not been converted into a table. Check the account, or retry with OCR if the PDF text is damaged.").foregroundStyle(.orange)
                        Toggle("Save the PDF for manual transaction entry", isOn: $allowEmptyImport)
                    } else {
                        Table(parsed.entries) {
                            TableColumn("Date", value: \.date).width(90)
                            TableColumn("Description", value: \.rawDescription).width(min: 220, ideal: 380)
                            TableColumn("HKD") { Text(Money.plain($0.amount)).monospacedDigit() }.width(110)
                        }.frame(height: 240)
                    }
                    DisclosureGroup("Extraction notes") { ForEach(parsed.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) } }

                }
            }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Skip file") { next() }.disabled(busy); Button((parsed?.entries.isEmpty ?? true) ? "Save PDF for manual entry" : "Import \(parsed?.entries.count ?? 0) transactions") { commit() }.buttonStyle(.borderedProminent).disabled(extracted == nil || account == nil || !Day.valid(periodEnd) || busy || (needsReplacementConfirmation && !replaceExisting) || ((parsed?.entries.isEmpty ?? true) && !allowEmptyImport)) }
        }.padding(24).frame(width: 760)
        .interactiveDismissDisabled(busy)
        .onAppear {
            forceOCR = store.forceOCRForImport
            if let url, let previous = store.workspace.statements.first(where: { store.pdfURL($0) == url }) { accountID = previous.accountID; periodEnd = previous.periodEnd; periodStart = previous.periodStart }
            read()
        }
        .onChange(of: accountID) { _, _ in reparse() }
        .onChange(of: periodEnd) { _, _ in reparse() }
        .onDisappear { reparseTask?.cancel() }
    }
    /// Parsing is regex-heavy; run off the main actor when inputs change.
    private func reparse() {
        guard let extracted, let account else { parsed = nil; return }
        reparseTask?.cancel()
        let pdf = extracted, acct = account, end = periodEnd, statementID = existing?.id ?? draftID
        reparseTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                StatementParser.parse(pdf, statementID: statementID, account: acct, periodEnd: end)
            }.value
            guard !Task.isCancelled else { return }
            parsed = result
        }
    }
    private func read() {
        guard let url else { return }; busy = true; message = nil; extracted = nil; parsed = nil
        let suppliedPassword = password, ocr = forceOCR
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try PDFExtractor.read(url: url, password: suppliedPassword, forceOCR: ocr)
                }.value
                extracted = result; password = ""
                if !suppliedPassword.isEmpty { store.pdfPasswords[result.hash] = suppliedPassword }
                if let date = result.suggestedPeriodEnd { periodEnd = date }
                if accountID == nil {
                    let matching = store.workspace.accounts.filter { $0.bank == result.bank }
                    if matching.count == 1 { accountID = matching[0].id }
                }
                if accountID == nil { message = "Choose the account above to build the transaction table." }
                reparse()
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func commit() {
        guard let url, let extracted, let account else { return }
        busy = true; message = nil
        let suppliedPeriodStart = periodStart, suppliedPeriodEnd = periodEnd, allowEmpty = allowEmptyImport, isReplace = existing != nil
        Task {
            defer { busy = false }
            do {
                guard suppliedPeriodStart.isEmpty || (Day.valid(suppliedPeriodStart) && suppliedPeriodStart <= suppliedPeriodEnd) else {
                    throw LedgerError.invalid("Enter a valid period start no later than the end.")
                }
                var statement = existing ?? Statement(accountID: account.id, filename: url.lastPathComponent, storedFilename: UUID().uuidString + ".pdf", hash: extracted.hash)
                if existing != nil {
                    let ids = Set(store.workspace.entries.filter { $0.statementID == statement.id }.map(\.id))
                    guard !store.workspace.allocations.contains(where: { ids.contains($0.entryID) }) else {
                        throw LedgerError.invalid("Reverse this statement's payment allocations before replacing its extraction.")
                    }
                }
                statement.accountID = account.id; statement.periodStart = suppliedPeriodStart; statement.periodEnd = suppliedPeriodEnd; statement.reconciled = false
                let pdf = extracted, acct = account
                let result = await Task.detached(priority: .userInitiated) {
                    StatementParser.parse(pdf, statementID: statement.id, account: acct, periodEnd: suppliedPeriodEnd)
                }.value
                guard !result.entries.isEmpty || allowEmpty else {
                    throw LedgerError.invalid("No transactions were extracted. Choose manual entry explicitly to keep an empty import.")
                }
                statement.parserVersion = StatementParser.version
                statement.manualEntry = result.entries.isEmpty ? true : nil
                statement.profile = result.profile; statement.warnings = result.warnings
                statement.openingBalance = result.openingBalance ?? statement.openingBalance; statement.closingBalance = result.closingBalance ?? statement.closingBalance
                var copiedOriginal: URL?
                if existing == nil {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let destination = store.pdfURL(statement)
                    try FileManager.default.copyItem(at: url, to: destination)
                    copiedOriginal = destination
                }
                // A failed import must not leave an unreferenced copy of the PDF in the app's storage.
                func discardCopy() { if let copiedOriginal { try? FileManager.default.removeItem(at: copiedOriginal) } }
                let snapshot = store.workspace
                let prepared: Workspace
                do {
                    prepared = try await Task.detached(priority: .userInitiated) {
                        var workspace = snapshot
                        try workspace.commitParsedStatement(statement, parseResult: result)
                        return workspace
                    }.value
                } catch { discardCopy(); throw error }
                store.error = nil
                let label = isReplace ? "Replace statement extraction" : "Import statement"
                // If anything changed the workspace while the import was prepared, apply it to the current state instead.
                if store.workspace == snapshot { store.change(label) { $0 = prepared } }
                else { store.change(label) { try $0.commitParsedStatement(statement, parseResult: result) } }
                guard store.error == nil else { discardCopy(); return }
                store.selectedStatement = statement.id; store.section = .statements; next()
            } catch { message = error.localizedDescription }
        }
    }
    private func next() {
        if index + 1 >= store.importURLs.count { dismiss() }
        else {
            // Each file starts clean: a date that is not detected must not silently inherit the previous file's period.
            index += 1; extracted = nil; parsed = nil; password = ""; message = nil; replaceExisting = false; accountID = nil
            periodEnd = Day.today; periodStart = ""; forceOCR = false; allowEmptyImport = false; draftID = UUID(); read()
        }
    }
}
struct InvoiceImportView: View {
    @Bindable var store: AppStore
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var sheets: [Sheet] = []
    @State private var sheetIndex = 0
    @State private var mapping: [String: Int] = [:]
    @State private var preview: [Invoice] = []
    @State private var message: String?
    @State private var busy = true
    @State private var acknowledgeUpdates = false
    var sheet: Sheet? { sheets.indices.contains(sheetIndex) ? sheets[sheetIndex] : nil }
    var updatedCount: Int { preview.filter { invoice in store.workspace.invoices.contains { $0.number.caseInsensitiveCompare(invoice.number) == .orderedSame } }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import invoice register").font(.title2.bold())
            Text(url.lastPathComponent).foregroundStyle(.secondary)
            Text("Outstanding amounts are the starting baseline. Do not reimport a current balance that already subtracts payments allocated in this app.").font(.callout)
            if busy { ProgressView("Reading spreadsheet…") }
            if !sheets.isEmpty {
                Picker("Worksheet", selection: $sheetIndex) { ForEach(sheets.indices, id: \.self) { Text(sheets[$0].name).tag($0) } }.onChange(of: sheetIndex) { _, _ in resetMapping() }
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    ForEach(InvoiceColumn.allCases) { column in
                        GridRow {
                            Text(column.rawValue + (column.required ? " *" : ""))
                            Picker(column.rawValue, selection: Binding(get: { mapping[column.rawValue] ?? -1 }, set: { mapping[column.rawValue] = $0; preview = []; acknowledgeUpdates = false })) {
                                Text(column == .currency ? "Default: HKD" : "Not mapped").tag(-1)
                                ForEach(Array((sheet?.rows.first ?? []).enumerated()), id: \.offset) { i, header in Text("\(i + 1): \(header)").tag(i) }
                            }.labelsHidden()
                            Text(sample(column)).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 180, alignment: .leading)
                        }
                    }
                }
                Button("Validate and preview") { validate() }
            }
            if let message { Text(message).foregroundStyle(.red).font(.callout) }
            if !preview.isEmpty {
                Text("\(preview.count) invoices · \(updatedCount) existing records will be updated").font(.headline)
                ScrollView { VStack(alignment: .leading) { ForEach(preview.prefix(6)) { invoice in HStack { Text(invoice.number); Text(invoice.client); Spacer(); Text(Money.display(invoice.startingOutstanding)) }.font(.caption) } } }.frame(height: 100)
                if updatedCount > 0 { Toggle("I reviewed the updates and starting balances; preserve existing allocations", isOn: $acknowledgeUpdates) }
            }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Import invoices") { commit() }.buttonStyle(.borderedProminent).disabled(preview.isEmpty || (updatedCount > 0 && !acknowledgeUpdates)) }
        }.padding(24).frame(width: 780)
        .task {
            do { sheets = try await Task.detached { let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; return try InvoiceReader.sheets(url: url) }.value; resetMapping() }
            catch { message = error.localizedDescription }; busy = false
        }
    }
    func sample(_ column: InvoiceColumn) -> String { guard let i = mapping[column.rawValue], let row = sheet?.rows.dropFirst().first, i >= 0, i < row.count else { return "" }; return row[i] }
    func resetMapping() { mapping = InvoiceReader.suggestedMapping(headers: sheet?.rows.first ?? []); if mapping.isEmpty { mapping = store.workspace.invoiceMapping }; preview = []; message = nil; acknowledgeUpdates = false }
    func validate() {
        guard let sheet else { return }
        do { let rows = try InvoiceReader.invoices(sheet: sheet, mapping: mapping); var candidate = store.workspace; try candidate.importInvoices(rows, filename: url.lastPathComponent); preview = rows; message = nil }
        catch { preview = []; message = error.localizedDescription }
    }
    func commit() {
        store.error = nil
        store.change("Import invoice register") { w in try w.importInvoices(preview, filename: url.lastPathComponent); w.invoiceMapping = mapping }
        if store.error == nil { store.section = .invoices; dismiss() }
    }
}
