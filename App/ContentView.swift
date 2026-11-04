import SwiftUI
import StatementCore
import PDFKit

struct ContentView: View {
    @Bindable var store: AppStore
    /// Shared between both layouts so hiding the sidebar sticks when switching sections.
    @State private var columns: NavigationSplitViewVisibility = .all
    /// Statements use Apple's standard three-column layout (sidebar → statement list → statement);
    /// the other sections, and the empty Statements screen, use two columns.
    private var showsStatementColumns: Bool { store.section == .statements && !store.workspace.statements.isEmpty }
    var body: some View {
        Group {
            if showsStatementColumns {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar
                } content: {
                    StatementsView(store: store).navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
                } detail: {
                    detailColumn { StatementDetailColumn(store: store) }
                }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar
                } detail: {
                    detailColumn { sectionView }
                }
            }
        }
        .task {
            // Let the first layout pass finish before the workspace mutates and redraws lists.
            await Task.yield()
            await store.recoverEmptyImports()
            store.organizeTransactions()
        }
        .onAppear { if store.workspace.businessName.isEmpty { store.showSettings = true } }
        .dropDestination(for: URL.self) { urls, _ in store.enqueue(urls); return true }
        .sheet(isPresented: $store.showAISettings) { AISettingsView(settings: store.ai) }
        .sheet(isPresented: $store.showSettings) { WorkspaceSettings(store: store) }
        .sheet(isPresented: $store.showPDFImport) { PDFImportView(store: store) }
        .sheet(isPresented: $store.showInvoiceImport) { if let url = store.invoiceURL { InvoiceImportView(store: store, url: url) } }
        .sheet(item: $store.editingEntry) { entry in EntryEditor(store: store, original: entry) }
        .alert("Unable to complete action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Statement Manager", systemImage: "building.columns.fill").font(.headline)
                Text(store.workspace.businessName.isEmpty ? "Your local financial workspace" : store.workspace.businessName).font(.caption).foregroundStyle(.secondary)
            }.padding(18)
            List(SidebarSection.allCases, selection: $store.section) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
            VStack(alignment: .leading, spacing: 8) {
                Label(store.ai.enabled ? "Local storage · AI enabled" : "Local processing · AI off", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Text("HKD · HSBC & Bank of China").font(.caption2).foregroundStyle(.secondary)
                Button("Workspace Settings…") { store.showSettings = true }.buttonStyle(.plain).font(.caption)
                Button("AI Settings…") { store.showAISettings = true }.buttonStyle(.plain).font(.caption)
            }.padding(18)
        }.navigationSplitViewColumnWidth(min: 220, ideal: 245)
    }
    @ViewBuilder private var sectionView: some View {
        switch store.section {
        case .statements: StatementsEmptyView(store: store)
        case .transactions: TransactionsView(store: store)
        case .invoices: InvoicesView(store: store)
        case .rules: RulesView(store: store)
        case .reports: ReportsView(store: store)
        }
    }
    /// The notice banner, title, busy overlay and toolbar shared by every section's detail column.
    private func detailColumn<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            if let notice = store.notice {
                HStack { Image(systemName: "checkmark.circle"); Text(notice); Spacer(); Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.callout).padding(12).background(.green.opacity(0.08))
            }
            content()
        }
        // Pin to the top: if a section is taller than the window, macOS would
        // otherwise centre it and push its top edge up under the toolbar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .navigationTitle(store.section.rawValue)
        .overlay {
            if store.busy {
                ZStack {
                    Color.black.opacity(0.06)
                    ProgressView("Working…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }.ignoresSafeArea()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { store.openPDFs() } label: { Label("Import Statements", systemImage: "square.and.arrow.down") }.disabled(store.showPDFImport)
                Menu {
                    Button("This statement to Excel…") { store.exportStatementExcel() }.disabled(store.selectedStatement == nil)
                    Button("All transactions to Excel…") { store.exportAllTransactionsExcel() }
                    Divider()
                    Button("Reviewed transactions (CSV)") { store.export("transactions") }
                    Button("Invoice balances") { store.export("invoices") }
                    Button("Payment allocations") { store.export("allocations") }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
            }
        }
    }
}
struct WorkspaceSettings: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var accountName = ""
    @State private var bank: Bank = .hsbc
    @State private var kind: AccountKind = .bank
    @State private var category = ""
    @State private var categoryToRename = "Software"
    @State private var replacementCategory = ""
    @State private var showAISettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.workspace.businessName.isEmpty ? "Set up your workspace" : "Workspace Settings").font(.title2.bold())
            HStack { Text("One business. HKD accounts. Local storage.").foregroundStyle(.secondary); Spacer(); Button("AI Settings…") { showAISettings = true } }
            TextField("Business name", text: $name)
            GroupBox("Accounts") {
                VStack(alignment: .leading) {
                    ForEach(store.workspace.accounts) { account in HStack { Text(account.name); Spacer(); Text("\(account.bank.rawValue) · \(account.kind.rawValue)").foregroundStyle(.secondary) } }
                    Divider()
                    HStack { TextField("Account nickname (e.g. HSBC operating)", text: $accountName); Picker("Bank", selection: $bank) { Text(Bank.hsbc.rawValue).tag(Bank.hsbc); Text(Bank.boc.rawValue).tag(Bank.boc) }.labelsHidden(); Picker("Type", selection: $kind) { ForEach(AccountKind.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden() }
                    Button("Add account") { store.change("Add account") { $0.accounts.append(Account(name: accountName.trimmingCharacters(in: .whitespaces), bank: bank, kind: kind)) }; accountName = "" }.disabled(accountName.trimmingCharacters(in: .whitespaces).isEmpty)
                }.padding(8)
            }
            GroupBox("Expense categories") {
                VStack(alignment: .leading) {
                    Text(store.workspace.categories.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    HStack { TextField("New category", text: $category); Button("Add") { store.error = nil; store.change("Add category") { _ = try $0.addClassificationItem(category, isType: false) }; if store.error == nil { category = "" } }.disabled(category.trimmingCharacters(in: .whitespaces).isEmpty || store.workspace.categories.contains(category)) }
                    HStack {
                        Picker("Rename", selection: $categoryToRename) { ForEach(store.workspace.categories.filter { $0 != "Uncategorized" }, id: \.self) { Text($0).tag($0) } }
                        TextField("New name", text: $replacementCategory)
                        Button("Rename") {
                            let name = replacementCategory.trimmingCharacters(in: .whitespacesAndNewlines), old = categoryToRename
                            store.error = nil
                            store.change("Rename expense category") { try $0.renameCategory(old, to: name) }
                            if store.error == nil { categoryToRename = name; replacementCategory = "" }
                        }.disabled(replacementCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(8)
            }
            Text("Protect this Mac with FileVault and use encrypted Time Machine backups. The app does not upload statements or connect to your bank.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Create Backup…") { store.backup() }; Button("Restore Backup…") { store.restore() }; Spacer(); Button("Save") { store.change("Update business name") { $0.businessName = name.trimmingCharacters(in: .whitespacesAndNewlines) }; dismiss() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.workspace.accounts.isEmpty) }
        }.padding(24).frame(width: 720).onAppear { name = store.workspace.businessName }
        .interactiveDismissDisabled(store.workspace.businessName.isEmpty)
        .sheet(isPresented: $showAISettings) { AISettingsView(settings: store.ai) }
    }
}
struct StatementsEmptyView: View {
    @Bindable var store: AppStore
    var body: some View {
        ContentUnavailableView { Label("Your statements, organized", systemImage: "doc.text") } description: { Text("Import searchable HSBC or Bank of China PDFs. Bank statements and credit card statements stay in separate folders.") } actions: { Button("Import Statements…") { store.openPDFs() }.buttonStyle(.borderedProminent) }
    }
}
/// Detail column of the Statements layout: the selected statement, or a prompt to pick one.
struct StatementDetailColumn: View {
    @Bindable var store: AppStore
    var body: some View {
        if let selected = store.workspace.statements.first(where: { $0.id == store.selectedStatement }) {
            StatementDetail(store: store, statement: selected).id(selected.id)
        } else {
            HSplitView {
                List(selection: $store.selectedStatement) {
                    ForEach(StatementFolder.allCases) { folder in folderSection(folder) }
                }.frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
                // Open the account folder of a newly selected statement (e.g. right after an import).
                .onChange(of: store.selectedStatement) { _, id in
                    guard let id, let account = store.workspace.statements.first(where: { $0.id == id })?.accountID,
                          collapsed.contains(account) else { return }
                    collapsed.remove(account)
                }
            }
        case .noStatements:
            placeholder("No statements yet", indent: 44)
        case .statement(let id):
            if let statement = store.workspace.statements.first(where: { $0.id == id }) {
                statementButton(statement)
            }
        }
    }
    private func disclosure<Label: View>(expanded: Bool, indent: CGFloat, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                label()
            }
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
    private func placeholder(_ text: String, indent: CGFloat) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.leading, indent).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func toggle(_ folder: StatementFolder) {
        if collapsedFolders.contains(folder) { collapsedFolders.remove(folder) } else { collapsedFolders.insert(folder) }
    }
    private func toggle(_ account: UUID) {
        if collapsedAccounts.contains(account) { collapsedAccounts.remove(account) } else { collapsedAccounts.insert(account) }
    }
    /// Expand the folder and account that own a newly selected statement, such as right after an import.
    private func revealSelection(_ id: UUID?) {
        guard let id, let accountID = store.workspace.statements.first(where: { $0.id == id })?.accountID else { return }
        let folder: StatementFolder?
        switch store.workspace.account(accountID)?.kind {
        case .bank: folder = .bank
        case .creditCard: folder = .creditCard
        case nil: folder = nil
        }
        let folderCollapsed = folder.map { collapsedFolders.contains($0) } ?? false
        guard collapsedAccounts.contains(accountID) || folderCollapsed else { return }
        collapsedAccounts.remove(accountID)
        if let folder { collapsedFolders.remove(folder) }
    }
    // A plain header row plus conditional rows, not a DisclosureGroup: inside a selectable List on macOS the outline
    // view's own expansion state fought the programmatic "reveal the selected statement" and the selection looped.
    @ViewBuilder private func accountFolder(_ account: Account) -> some View {
        let items: [Statement] = store.workspace.statements(forAccount: account.id)
        let expanded: Bool = !collapsed.contains(account.id)
        accountLabel(account, count: items.count, expanded: expanded)
        if expanded {
            if items.isEmpty { Text("No statements yet").font(.caption).foregroundStyle(.secondary).padding(.leading, 22) }
            ForEach(items) { statement in statementRow(statement).padding(.leading, 22).tag(statement.id) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func accountLabel(_ account: Account, count: Int, expanded: Bool) -> some View {
        let help: String = account.bank.rawValue + " · " + account.kind.rawValue
        return Button {
            if expanded { collapsed.insert(account.id) } else { collapsed.remove(account.id) }
        } label: {
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 12)
                Label(account.name, systemImage: "folder")
                Spacer()
                Text(String(count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }
    private static func folderIcon(_ folder: StatementFolder) -> String {
        switch folder {
        case .bank: return "building.columns"
        case .creditCard: return "creditcard"
        }
    }
    private func statementRow(_ statement: Statement) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(statement.filename).font(.headline).lineLimit(2)
            HStack { Text(statement.periodEnd); Spacer(); Label(statement.reconciled ? "Reconciled" : "Review", systemImage: statement.reconciled ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(statement.reconciled ? .green : .orange) }.font(.caption)
        }.padding(.vertical, 6)
    }
}
struct StatementDetail: View {
    @Bindable var store: AppStore
    var statement: Statement
    @State private var opening = ""
    @State private var closing = ""
    @State private var showPDF = true
    @State private var pdfLocked: Bool
    @State private var unlockPassword = ""
    @State private var unlockMessage: String?
    init(store: AppStore, statement: Statement) {
        self.store = store
        self.statement = statement
        // Decide before the first layout, so the detail does not change shape right after it appears.
        _pdfLocked = State(initialValue: PDFDocument(url: store.pdfURL(statement))?.isLocked ?? false)
    }
    var entries: [Entry] { store.workspace.entries.filter { $0.statementID == statement.id } }
    var selectedEntry: Entry? { entries.first { $0.id == store.selectedStatementEntry } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { VStack(alignment: .leading) { Text(statement.filename).font(.title3.bold()); Text(statement.profile).font(.caption).foregroundStyle(.secondary) }; Spacer(); Menu { Button("Retry with OCR…") { store.reextract(statement, forceOCR: true) }; Button("Roll back import…", role: .destructive) { store.removeStatement(statement) } } label: { Image(systemName: "ellipsis.circle") } }
            DisclosureGroup("Import notes (\(statement.warnings.count))") {
                // A long list of notes scrolls here rather than making the statement taller than the window.
                ScrollView { VStack(alignment: .leading, spacing: 2) { ForEach(statement.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) } } }
                    .frame(maxHeight: 110)
            }
            HStack {
                TextField("Opening HKD", text: $opening).frame(width: 125)
                TextField("Closing HKD", text: $closing).frame(width: 125)
                Button("Save balances") {
                    do { let a = try Money.parse(opening), b = try Money.parse(closing); store.change("Update statement balances") { w in if let i = w.statements.firstIndex(where: { $0.id == statement.id }) { w.statements[i].openingBalance = a; w.statements[i].closingBalance = b; w.statements[i].reconciled = false } } } catch { store.error = error.localizedDescription }
                }
                Spacer()
                if let difference = store.workspace.reconciliationDifference(statement) { Text(difference == 0 ? "Balanced" : "Difference: \(Money.display(difference))").font(.caption.bold()).foregroundStyle(difference == 0 ? .green : .orange) }
            }
            Text(store.workspace.account(statement.accountID)?.kind == .creditCard ? "Card amounts: charges are positive; repayments and credits are negative. Balances represent the amount owed." : "Bank amounts: money received is positive; money paid is negative.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HSplitView {
                VStack(alignment: .leading) {
                    HStack {
                        Text("\(entries.count) transactions").font(.headline)
                        Spacer()
                        Button("Export all to Excel…") { store.exportStatementExcel(statementID: statement.id) }
                            .help("Excel workbook of every transaction on this statement, including rows that still need review.")
                        Toggle("Show PDF", isOn: $showPDF).toggleStyle(.checkbox)
                        Button("Add row") { store.newEntry(statement: statement) }
                    }
                    if entries.isEmpty {
                        ContentUnavailableView { Label("No transactions extracted", systemImage: "tablecells.badge.ellipsis") } description: { Text("The PDF was saved, but the earlier parser could not build its table.") } actions: { Button("Extract transactions") { store.reextract(statement) }.buttonStyle(.borderedProminent) }
                    } else { EntryTable(store: store, entries: entries, selection: $store.selectedStatementEntry) }
                    HStack { Text("\(entries.filter(\.reviewed).count) reviewed").font(.caption).foregroundStyle(.secondary); Spacer(); Button(statement.reconciled ? "Reconciled" : "Mark reconciled") { store.change("Reconcile statement") { w in if let i = w.statements.firstIndex(where: { $0.id == statement.id }) { w.statements[i].reconciled = true } } }.disabled(statement.reconciled || store.workspace.reconciliationDifference(statement) != 0 || entries.contains { !$0.reviewed || $0.duplicateCandidate }) }
                }.frame(minWidth: 440)
                if showPDF {
                    VStack(alignment: .leading, spacing: 6) {
                        if pdfLocked && store.pdfPasswords[statement.hash] == nil {
                            // The preserved original stays protected; the password is held in memory for this session only.
                            // A locked PDF is never handed to PDFView: it has no page to fit and kept re-running layout.
                            HStack { SecureField("PDF password to show the preview", text: $unlockPassword).onSubmit { unlockPreview() }; Button("Unlock") { unlockPreview() }.disabled(unlockPassword.isEmpty) }
                            if let unlockMessage { Text(unlockMessage).font(.caption).foregroundStyle(.red) }
                            ContentUnavailableView("PDF is password protected", systemImage: "lock.doc", description: Text("Enter the PDF password to show the preview."))
                        } else {
                            PDFPreview(url: store.pdfURL(statement), region: selectedEntry?.source, password: store.pdfPasswords[statement.hash])
                        }
                    }.frame(minWidth: 240)
                }
            }
            // Takes whatever height is left and is allowed to shrink, so the header above stays on screen.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }.padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onAppear { refreshBalances() }
        .onChange(of: statement.openingBalance) { _, _ in refreshBalances() }
        .onChange(of: statement.closingBalance) { _, _ in refreshBalances() }
    }
    private func unlockPreview() {
        guard let document = PDFDocument(url: store.pdfURL(statement)), document.unlock(withPassword: unlockPassword) else { unlockMessage = "That password does not open this PDF."; return }
        store.pdfPasswords[statement.hash] = unlockPassword; unlockPassword = ""; unlockMessage = nil
    }
    private func refreshBalances() { opening = statement.openingBalance.map(Money.plain) ?? ""; closing = statement.closingBalance.map(Money.plain) ?? "" }
}
struct EntryTable: View {
    @Bindable var store: AppStore
    var entries: [Entry]
    @Binding var selection: UUID?
    var body: some View {
        Table(entries, selection: $selection) {
            TableColumn("Date", value: \.date).width(85)
            TableColumn("Description") { e in VStack(alignment: .leading, spacing: 3) { Text(e.rawDescription).lineLimit(2); HStack { if e.usedOCR { Text("OCR") }; if e.duplicateCandidate { Text("Possible duplicate") }; if e.reviewed { Text("Reviewed") } else { Text("Needs review") } }.font(.caption2).foregroundStyle(e.reviewed ? Color.secondary : Color.orange) } }.width(min: 140, ideal: 220)
            TableColumn("Payee / Client") { Text($0.payee.isEmpty ? "—" : $0.payee).lineLimit(2).help($0.payee) }.width(min: 110, ideal: 160)
            TableColumn("HKD") { Text(Money.signed($0.amount)).monospacedDigit() }.width(95)
            TableColumn("Type") { Text($0.typeTitle) }.width(min: 115, ideal: 135)
            TableColumn("Reference") { Text($0.referenceSummary.isEmpty ? "—" : $0.referenceSummary).lineLimit(2).help($0.referenceSummary) }.width(min: 110, ideal: 160)
            TableColumn("Category", value: \.category).width(min: 100, ideal: 130)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let e = entries.first(where: { $0.id == id }) { Button("Review / Edit…") { store.editingEntry = e } }
        } primaryAction: { ids in if let id = ids.first { store.editingEntry = entries.first { $0.id == id } } }
        Button("Review selected transaction…") { store.editingEntry = entries.first { $0.id == selection } }.disabled(!entries.contains { $0.id == selection })
    }
}
struct TransactionsView: View {
    @Bindable var store: AppStore
    @State private var search = ""
    @State private var onlyReview = false
    @State private var direction: RuleDirection = .any
    @State private var sort = "Date"
    var entries: [Entry] { store.workspace.entries.filter { (direction == .any || (direction == .incoming ? store.workspace.incoming($0) > 0 : store.workspace.incoming($0) < 0)) && (!onlyReview || !$0.reviewed || $0.duplicateCandidate) && (search.isEmpty || ($0.rawDescription + $0.payee + $0.category + $0.referenceSummary + $0.typeTitle).localizedCaseInsensitiveContains(search)) }.sorted {
        if sort == "Category", $0.category != $1.category { return $0.category < $1.category }
        if sort == "Type", $0.typeTitle != $1.typeTitle { return $0.typeTitle < $1.typeTitle }
        return $0.date > $1.date
    } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { TextField("Search descriptions, clients, references…", text: $search).textFieldStyle(.roundedBorder); Toggle("Needs review", isOn: $onlyReview).toggleStyle(.checkbox); Button("Export Excel…") { store.exportAllTransactionsExcel() }.help("Writes one Excel workbook per account, in its own folder under Bank statements or Credit card statements, including rows that still need review."); Button("Apply rules") { store.applyRulesInBackground() }.disabled(store.busy) }
            HStack {
                Picker("Direction", selection: $direction) { Text("All").tag(RuleDirection.any); Text("Credits / money in").tag(RuleDirection.incoming); Text("Debits / money out").tag(RuleDirection.outgoing) }.frame(width: 270)
                Picker("Sort by", selection: $sort) { ForEach(["Date", "Type", "Category"], id: \.self) { Text($0) } }.frame(width: 200)
                Text("Bank: + credit, − debit. Card: + charge, − repayment/refund.").font(.caption).foregroundStyle(.secondary)
            }
            if store.workspace.entries.isEmpty { ContentUnavailableView("No transactions yet", systemImage: "list.bullet.rectangle", description: Text("Import a statement, then review its extracted transactions.")) }
                    else { EntryTable(store: store, entries: entries, selection: $store.selectedStatementEntry) }
        }.padding(20)
    }
}
/// Hosts a PDFView without letting it re-enter AppKit layout.
///
/// `PDFView.autoScales` calls `-layoutSubtreeIfNeeded` from inside an in-progress
/// layout pass. SwiftUI also invokes `updateNSView` from that pass, and the old
/// preview reapplied the highlight and `go(to:)` on every update. Together those
/// recurse through the statement split view ("It's not legal to call
/// -layoutSubtreeIfNeeded on a view which is already being laid out") and can
/// wedge the main thread.
final class PDFHostView: NSView {
    let pdfView: PDFView
    private var fittedSize = NSSize.zero
    private var fitScheduled = false

    override init(frame frameRect: NSRect) {
        let pdf = PDFView()
        pdf.autoScales = false
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.minScaleFactor = 0.1
        pdf.maxScaleFactor = 4
        pdfView = pdf
        super.init(frame: frameRect)
        pdf.frame = bounds
        pdf.autoresizingMask = [.width, .height]
        addSubview(pdf)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1, !sizesMatch(fittedSize, bounds.size), !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            self.fitToBounds()
        }
    }

    /// Fit the current page after the enclosing layout pass. Returns false when there is nothing to fit yet.
    @discardableResult func fitToBounds() -> Bool {
        guard bounds.width > 1, bounds.height > 1 else { return false }
        // Nothing to fit yet: remember this size so layout() does not reschedule a fit on every pass.
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { fittedSize = bounds.size; return false }
        let pageSize = page.bounds(for: pdfView.displayBox).size
        guard pageSize.width > 0, pageSize.height > 0 else { fittedSize = bounds.size; return false }
        let factor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, min(bounds.width / pageSize.width, bounds.height / pageSize.height)))
        fittedSize = bounds.size
        if abs(pdfView.scaleFactor - factor) > 0.01 { pdfView.scaleFactor = factor }
        return true
    }

    func invalidateFit() { fittedSize = .zero }

    private func sizesMatch(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }
}

struct PDFPreview: NSViewRepresentable {
    var url: URL
    var region: SourceRegion?
    var password: String? = nil

    final class Coordinator {
        var appliedURL: URL?
        var appliedPassword: String?
        var appliedRegion: SourceRegion?
        var annotation: PDFAnnotation?
        weak var page: PDFPage?
        var fitted = false
        var generation = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFHostView { PDFHostView() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFHostView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ host: PDFHostView, context: Context) {
        let coordinator = context.coordinator
        let reload = coordinator.appliedURL != url || coordinator.appliedPassword != password
        let regionChanged = coordinator.appliedRegion != region
        guard reload || regionChanged || !coordinator.fitted else { return }
        if reload { host.invalidateFit() }
        coordinator.generation += 1
        let generation = coordinator.generation
        let url = url
        let region = region
        let password = password
        // Document, scale, highlight, and scrolling all invalidate PDF layout.
        // Apply them on the next turn so this update is not nested inside SwiftUI's layout.
        DispatchQueue.main.async {
            guard coordinator.generation == generation else { return }
            let pdf = host.pdfView
            if reload || pdf.document == nil {
                if let annotation = coordinator.annotation { coordinator.page?.removeAnnotation(annotation) }
                coordinator.annotation = nil
                coordinator.page = nil
                let document = PDFDocument(url: url)
                if let document, document.isLocked, let password { _ = document.unlock(withPassword: password) }
                // A still-locked document has no pages to fit; showing it would retry the fit on every update.
                pdf.document = (document?.isLocked ?? false) ? nil : document
                host.invalidateFit()
            }
            if reload || regionChanged {
                if let annotation = coordinator.annotation {
                    coordinator.page?.removeAnnotation(annotation)
                    coordinator.annotation = nil
                    coordinator.page = nil
                }
            }
            // Scale before scrolling so the fit does not jump away from the highlight.
            let fitted = host.fitToBounds()
            if reload || regionChanged, let region, let page = pdf.document?.page(at: region.page) {
                let annotation = PDFAnnotation(bounds: region.rect, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.35)
                page.addAnnotation(annotation)
                coordinator.annotation = annotation
                coordinator.page = page
                pdf.go(to: region.rect.insetBy(dx: -10, dy: -30), on: page)
            }
            coordinator.appliedURL = url
            coordinator.appliedPassword = password
            // A missing file or a view that has no size yet must not re-enter layout.
            // Keep the region pending until the page has actually been fitted, so the highlight scroll runs after that fit.
            if fitted || pdf.document == nil {
                coordinator.appliedRegion = region
                coordinator.fitted = fitted || pdf.document == nil
            }
        }
    }
}
