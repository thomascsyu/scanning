import SwiftUI
import StatementCore
import PDFKit

struct ContentView: View {
    @Bindable var store: AppStore
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Statement Manager", systemImage: "building.columns.fill").font(.headline)
                    Text(store.workspace.businessName.isEmpty ? "Your local financial workspace" : store.workspace.businessName).font(.caption).foregroundStyle(.secondary)
                }.padding(18)
                List(Section.allCases, selection: $store.section) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                VStack(alignment: .leading, spacing: 8) {
                    Label(store.ai.enabled ? "Local storage · AI enabled" : "Local processing · AI off", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    Text("HKD · HSBC & Bank of China").font(.caption2).foregroundStyle(.secondary)
                    Button("Workspace Settings…") { store.showSettings = true }.buttonStyle(.plain).font(.caption)
                    Button("AI Settings…") { store.showAISettings = true }.buttonStyle(.plain).font(.caption)
                }.padding(18)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 245)
        } detail: {
            VStack(spacing: 0) {
                if let notice = store.notice {
                    HStack { Image(systemName: "checkmark.circle"); Text(notice); Spacer(); Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.callout).padding(12).background(.green.opacity(0.08))
                }
                switch store.section {
                case .statements: StatementsView(store: store)
                case .transactions: TransactionsView(store: store)
                case .invoices: InvoicesView(store: store)
                case .rules: RulesView(store: store)
                case .reports: ReportsView(store: store)
                }
            }
            .navigationTitle(store.section.rawValue)
            .toolbar {
                ToolbarItemGroup {
                    Button { store.openPDFs() } label: { Label("Import Statements", systemImage: "square.and.arrow.down") }.disabled(store.showPDFImport)
                    Menu { Button("Transactions") { store.export("transactions") }; Button("Invoice balances") { store.export("invoices") }; Button("Payment allocations") { store.export("allocations") } } label: { Label("Export", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .task { await store.recoverEmptyImports(); store.organizeTransactions() }
        .onAppear { if store.workspace.businessName.isEmpty { store.showSettings = true } }
        .dropDestination(for: URL.self) { urls, _ in store.enqueue(urls); return true }
        .sheet(isPresented: $store.showAISettings) { AISettingsView(settings: store.ai) }
        .sheet(isPresented: $store.showSettings) { WorkspaceSettings(store: store) }
        .sheet(isPresented: $store.showPDFImport) { PDFImportView(store: store) }
        .sheet(isPresented: $store.showInvoiceImport) { if let url = store.invoiceURL { InvoiceImportView(store: store, url: url) } }
        .sheet(item: $store.editingEntry) { entry in EntryEditor(store: store, original: entry) }
        .alert("Unable to complete action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
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
                            let name = replacementCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                            store.change("Rename expense category") { w in
                                if let i = w.categories.firstIndex(of: categoryToRename) { w.categories[i] = name }
                                for i in w.entries.indices where w.entries[i].category == categoryToRename { w.entries[i].category = name }
                                for i in w.rules.indices where w.rules[i].category == categoryToRename { w.rules[i].category = name }
                            }
                            categoryToRename = name; replacementCategory = ""
                        }.disabled(replacementCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.workspace.categories.contains(replacementCategory.trimmingCharacters(in: .whitespacesAndNewlines)))
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
struct StatementsView: View {
    @Bindable var store: AppStore
    var selected: Statement? { store.workspace.statements.first { $0.id == store.selectedStatement } }
    var body: some View {
        if store.workspace.statements.isEmpty {
            ContentUnavailableView { Label("Your statements, organized", systemImage: "doc.text") } description: { Text("Import searchable HSBC or Bank of China PDFs. Review extracted rows alongside the original before reconciling.") } actions: { Button("Import Statements…") { store.openPDFs() }.buttonStyle(.borderedProminent) }
        } else {
            HSplitView {
                List(selection: $store.selectedStatement) {
                    ForEach(store.workspace.statements.sorted { $0.importedAt > $1.importedAt }) { s in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(s.filename).font(.headline).lineLimit(2)
                            Text(store.workspace.account(s.accountID)?.name ?? "").font(.caption).foregroundStyle(.secondary)
                            HStack { Text(s.periodEnd); Spacer(); Label(s.reconciled ? "Reconciled" : "Review", systemImage: s.reconciled ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(s.reconciled ? .green : .orange) }.font(.caption)
                        }.padding(.vertical, 6).tag(s.id)
                    }
                }.frame(minWidth: 230, idealWidth: 240, maxWidth: 270)
                if let selected { StatementDetail(store: store, statement: selected).id(selected.id) }
                else { ContentUnavailableView("Select a statement", systemImage: "doc.text.magnifyingglass") }
            }
        }
    }
}
struct StatementDetail: View {
    @Bindable var store: AppStore
    var statement: Statement
    @State private var opening = ""
    @State private var closing = ""
    @State private var showPDF = true
    var entries: [Entry] { store.workspace.entries.filter { $0.statementID == statement.id } }
    var selectedEntry: Entry? { entries.first { $0.id == store.selectedEntry } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { VStack(alignment: .leading) { Text(statement.filename).font(.title3.bold()); Text(statement.profile).font(.caption).foregroundStyle(.secondary) }; Spacer(); Menu { Button("Retry with OCR…") { store.reextract(statement, forceOCR: true) }; Button("Roll back import…", role: .destructive) { store.removeStatement(statement) } } label: { Image(systemName: "ellipsis.circle") } }
            DisclosureGroup("Import notes (\(statement.warnings.count))") { ForEach(statement.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) } }
            HStack {
                TextField("Opening HKD", text: $opening).frame(width: 125)
                TextField("Closing HKD", text: $closing).frame(width: 125)
                Button("Save balances") {
                    do { let a = try Money.parse(opening), b = try Money.parse(closing); store.change("Update statement balances") { w in if let i = w.statements.firstIndex(where: { $0.id == statement.id }) { w.statements[i].openingBalance = a; w.statements[i].closingBalance = b; w.statements[i].reconciled = false } } } catch { store.error = error.localizedDescription }
                }
                Spacer()
                if let difference = store.workspace.reconciliationDifference(statement) { Text(difference == 0 ? "Balanced" : "Difference: \(Money.display(difference))").font(.caption.bold()).foregroundStyle(difference == 0 ? .green : .orange) }
            }
            Text(store.workspace.account(statement.accountID)?.kind == .creditCard ? "Card amounts: charges are positive; repayments and credits are negative. Balances represent the amount owed." : "Bank amounts: money received is positive; money paid is negative.").font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading) {
                    HStack { Text("\(entries.count) transactions").font(.headline); Spacer(); Toggle("Show PDF", isOn: $showPDF).toggleStyle(.checkbox); Button("Add row") { store.newEntry(statement: statement) } }
                    if entries.isEmpty {
                        ContentUnavailableView { Label("No transactions extracted", systemImage: "tablecells.badge.ellipsis") } description: { Text("The PDF was saved, but the earlier parser could not build its table.") } actions: { Button("Extract transactions") { store.reextract(statement) }.buttonStyle(.borderedProminent) }
                    } else { EntryTable(store: store, entries: entries) }
                    HStack { Text("\(entries.filter(\.reviewed).count) reviewed").font(.caption).foregroundStyle(.secondary); Spacer(); Button(statement.reconciled ? "Reconciled" : "Mark reconciled") { store.change("Reconcile statement") { w in if let i = w.statements.firstIndex(where: { $0.id == statement.id }) { w.statements[i].reconciled = true } } }.disabled(statement.reconciled || store.workspace.reconciliationDifference(statement) != 0 || entries.contains { !$0.reviewed || $0.duplicateCandidate }) }
                }.frame(minWidth: 440)
                if showPDF { PDFPreview(url: store.pdfURL(statement), region: selectedEntry?.source).frame(minWidth: 240) }
            }
        }.padding(16).onAppear { refreshBalances() }
        .onChange(of: statement.openingBalance) { _, _ in refreshBalances() }
        .onChange(of: statement.closingBalance) { _, _ in refreshBalances() }
    }
    private func refreshBalances() { opening = statement.openingBalance.map(Money.plain) ?? ""; closing = statement.closingBalance.map(Money.plain) ?? "" }
}
struct EntryTable: View {
    @Bindable var store: AppStore
    var entries: [Entry]
    var body: some View {
        Table(entries, selection: $store.selectedEntry) {
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
        Button("Review selected transaction…") { store.editingEntry = entries.first { $0.id == store.selectedEntry } }.disabled(!entries.contains { $0.id == store.selectedEntry })
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
            HStack { TextField("Search descriptions, clients, references…", text: $search).textFieldStyle(.roundedBorder); Toggle("Needs review", isOn: $onlyReview).toggleStyle(.checkbox); Button("Apply rules") { store.change("Apply categorization rules") { $0.applyRules() } } }
            HStack {
                Picker("Direction", selection: $direction) { Text("All").tag(RuleDirection.any); Text("Credits / money in").tag(RuleDirection.incoming); Text("Debits / money out").tag(RuleDirection.outgoing) }.frame(width: 270)
                Picker("Sort by", selection: $sort) { ForEach(["Date", "Type", "Category"], id: \.self) { Text($0) } }.frame(width: 200)
                Text("Bank: + credit, − debit. Card: + charge, − repayment/refund.").font(.caption).foregroundStyle(.secondary)
            }
            if store.workspace.entries.isEmpty { ContentUnavailableView("No transactions yet", systemImage: "list.bullet.rectangle", description: Text("Import a statement, then review its extracted transactions.")) }
            else { EntryTable(store: store, entries: entries) }
        }.padding(20)
    }
}
struct PDFPreview: NSViewRepresentable {
    var url: URL
    var region: SourceRegion?
    final class Coordinator { var url: URL?; var annotation: PDFAnnotation?; weak var page: PDFPage? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.url != url { view.document = PDFDocument(url: url); context.coordinator.url = url }
        if let annotation = context.coordinator.annotation { context.coordinator.page?.removeAnnotation(annotation); context.coordinator.annotation = nil }
        if let region, let page = view.document?.page(at: region.page) {
            let annotation = PDFAnnotation(bounds: region.rect, forType: .highlight, withProperties: nil); annotation.color = NSColor.systemYellow.withAlphaComponent(0.35)
            page.addAnnotation(annotation); context.coordinator.annotation = annotation; context.coordinator.page = page; view.go(to: region.rect.insetBy(dx: -10, dy: -30), on: page)
        }
    }
}
