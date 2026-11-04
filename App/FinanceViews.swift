import SwiftUI
import StatementCore

struct InvoicesView: View {
    @Bindable var store: AppStore
    @State private var search = ""
    @State private var showAllocation = false
    @State private var aliases = ""
    var selected: Invoice? { store.workspace.invoices.first { $0.id == store.selectedInvoice } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("Search invoice number or client…", text: $search).textFieldStyle(.roundedBorder)
                Button("Import Excel / CSV…") { store.openInvoices() }.buttonStyle(.borderedProminent)
                Menu {
                    Button("Export balances…") { store.export("invoices") }
                    Button("Export allocations…") { store.export("allocations") }
                    Button("Roll back latest invoice import") { store.change("Roll back invoice import") { try $0.rollbackLatestInvoiceBatch() } }.disabled(store.workspace.invoiceBatches.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
            }
            if store.workspace.invoices.isEmpty {
                ContentUnavailableView("Bring in your invoice register", systemImage: "doc.text.magnifyingglass", description: Text("Import Excel or CSV, map the columns, then match reviewed bank payments to invoices."))
            } else {
                Table(store.workspace.invoices.filter { search.isEmpty || ($0.number + $0.client).localizedCaseInsensitiveContains(search) }, selection: $store.selectedInvoice) {
                    TableColumn("Invoice", value: \.number)
                    TableColumn("Client", value: \.client)
                    TableColumn("Date", value: \.date).width(90)
                    TableColumn("Outstanding") { Text(Money.display(store.workspace.outstanding($0))).monospacedDigit() }.width(140)
                    TableColumn("Status") { Text(store.workspace.invoiceStatus($0)).foregroundStyle(store.workspace.invoiceStatus($0) == "Overdue" ? Color.orange : Color.secondary) }.width(110)
                }
                HStack { Text("\(store.workspace.invoices.count) invoices").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Match a payment…") { showAllocation = true }.buttonStyle(.borderedProminent) }
                if let selected {
                    GroupBox("Invoice \(selected.number)") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("Original: \(Money.display(selected.total))"); Text("Starting balance: \(Money.display(selected.startingOutstanding))"); Text("Due: \(selected.dueDate.isEmpty ? "Not specified" : selected.dueDate)") }.font(.caption)
                            HStack { TextField("Client aliases separated by semicolons", text: $aliases); Button("Save aliases") { store.change("Edit client aliases") { w in if let i = w.invoices.firstIndex(where: { $0.id == selected.id }) { w.invoices[i].aliases = aliases } } } }
                            ForEach(store.workspace.allocations.filter { $0.invoiceID == selected.id }) { allocation in
                                HStack {
                                    Text(store.workspace.entries.first { $0.id == allocation.entryID }?.date ?? "")
                                    Text("Payment: \(Money.display(allocation.amount))")
                                    Spacer()
                                    Button("Reverse allocation") { store.change("Reverse invoice allocation") { $0.allocations.removeAll { $0.id == allocation.id } } }
                                }.font(.caption)
                            }
                        }.padding(8)
                    }.onAppear { aliases = selected.aliases }.onChange(of: selected.id) { _, _ in aliases = selected.aliases }
                }
            }
        }.padding(20).sheet(isPresented: $showAllocation) { AllocationView(store: store) }
    }
}
struct AllocationView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var entryID: UUID?
    @State private var invoiceID: UUID?
    @State private var amount = ""
    @State private var message: String?
    var payments: [Entry] { store.workspace.entries.filter { store.workspace.account($0.accountID)?.kind == .bank && $0.reviewed && $0.type != .transfer && $0.type != .refund && $0.amount - store.workspace.allocated($0.id) > 0 } }
    var payment: Entry? { payments.first { $0.id == entryID } }
    var invoice: Invoice? { store.workspace.invoices.first { $0.id == invoiceID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Allocate a client payment").font(.title2.bold())
            Text("Suggestions are not posted automatically. Confirm the client and invoice against your records. Allocate again to split a payment across invoices.").foregroundStyle(.secondary)
            Picker("Reviewed incoming payment", selection: $entryID) {
                Text("Choose payment").tag(nil as UUID?)
                ForEach(payments) { e in Text("\(e.date) · \(e.rawDescription.prefix(60)) · \(Money.display(e.amount - store.workspace.allocated(e.id))) available").tag(Optional(e.id)) }
            }
            if payments.isEmpty { Text("Review an incoming bank transaction before allocating it. Transfers and refunds are excluded.").foregroundStyle(.orange) }
            if let payment {
                let suggestions = store.workspace.suggestions(for: payment)
                if !suggestions.isEmpty {
                    Text("Suggested matches").font(.headline)
                    ForEach(suggestions.prefix(5)) { i in Button("\(i.number) · \(i.client) · \(Money.display(store.workspace.outstanding(i)))") { invoiceID = i.id; fillAmount() }.buttonStyle(.link) }
                }
            }
            Picker("Invoice", selection: $invoiceID) {
                Text("Choose invoice").tag(nil as UUID?)
                ForEach(store.workspace.invoices.filter { store.workspace.outstanding($0) > 0 }) { i in Text("\(i.number) · \(i.client) · \(Money.display(store.workspace.outstanding(i)))").tag(Optional(i.id)) }
            }
            TextField("Amount to allocate in HKD", text: $amount)
            if let message { Text(message).foregroundStyle(.red) }
            HStack { Button("Close") { dismiss() }; Spacer(); Button("Confirm allocation") { allocate() }.buttonStyle(.borderedProminent).disabled(payment == nil || invoice == nil) }
        }.padding(24).frame(width: 760)
        .onAppear { invoiceID = store.selectedInvoice }
        .onChange(of: entryID) { _, _ in fillAmount() }
        .onChange(of: invoiceID) { _, _ in fillAmount() }
    }
    func fillAmount() { if let payment, let invoice { amount = Money.plain(min(payment.amount - store.workspace.allocated(payment.id), store.workspace.outstanding(invoice))) } }
    func allocate() {
        guard let entryID, let invoiceID else { return }
        do { let value = try Money.parse(amount); store.error = nil; store.change("Allocate client payment") { try $0.allocate(entryID: entryID, invoiceID: invoiceID, amount: value) }; if let error = store.error { message = error; store.error = nil } else { message = nil; amount = ""; self.entryID = nil; store.notice = "Payment allocation recorded." } }
        catch { message = error.localizedDescription }
    }
}
struct RulesView: View {
    @Bindable var store: AppStore
    @State private var editing: CategoryRule?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Rules suggest categories; your reviewed corrections take priority.").foregroundStyle(.secondary); Spacer(); Button("Add rule") { editing = CategoryRule() }.buttonStyle(.borderedProminent); Button("Apply rules") { store.change("Apply categorization rules") { $0.applyRules() } } }
            if store.workspace.rules.isEmpty { ContentUnavailableView("Teach the app your categories", systemImage: "slider.horizontal.3", description: Text("Create narrow rules for known merchants. Preview matches before saving. Unknown transactions remain in review.")) }
            else {
                List {
                    ForEach(store.workspace.rules.sorted { ($0.stage.rawValue, $0.priority) < ($1.stage.rawValue, $1.priority) }) { rule in
                        HStack {
                            Image(systemName: rule.enabled ? "checkmark.circle.fill" : "pause.circle").foregroundStyle(rule.enabled ? Color.green : Color.secondary)
                            VStack(alignment: .leading) { Text(rule.name).font(.headline); Text("\(rule.stage.title) · Priority \(rule.priority) · Contains ‘\(rule.pattern)’ → \(rule.customType ?? (rule.type == .transfer ? "Internal Transfer" : rule.category))").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Button("Edit…") { editing = rule }; Button("Delete", role: .destructive) { store.change("Delete categorization rule") { $0.rules.removeAll { $0.id == rule.id } } }
                        }.padding(.vertical, 6)
                    }
                }
            }
        }.padding(20).sheet(item: $editing) { RuleEditor(store: store, original: $0) }
    }
}
struct RuleEditor: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule: CategoryRule
    @State private var previewed = false
    @State private var applyNow = false
    init(store: AppStore, original: CategoryRule) { self.store = store; _rule = State(initialValue: original) }
    var matches: [Entry] { store.workspace.entries.filter { !$0.manuallyEdited && !$0.reviewed && store.workspace.ruleMatches(rule, $0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Categorization rule").font(.title2.bold())
            TextField("Rule name", text: $rule.name)
            Toggle("Enabled", isOn: $rule.enabled)
            HStack { Picker("Stage", selection: $rule.stage) { ForEach(RuleStage.allCases) { Text($0.title).tag($0) } }; Stepper("Priority \(rule.priority)", value: $rule.priority, in: 0...999) }
            Picker("Account", selection: $rule.accountID) { Text("All accounts").tag(nil as UUID?); ForEach(store.workspace.accounts) { Text($0.name).tag(Optional($0.id)) } }
            Picker("Direction", selection: $rule.direction) { ForEach(RuleDirection.allCases) { Text($0.rawValue).tag($0) } }
            TextField("Description contains (English or Chinese)", text: $rule.pattern)
            ClassificationFields(store: store, type: $rule.type, customType: $rule.customType, category: $rule.category)
            if rule.stage == .transfer { Text("Only use a transfer rule for confirmed movements between your own accounts. Matching words alone do not establish a transfer.").font(.caption).foregroundStyle(.orange) }
            Button("Preview affected transactions") { previewed = true }
            if previewed {
                Text("\(matches.count) unreviewed transactions match. Equal-priority conflicting rules leave rows unclassified.").font(.caption)
                ScrollView { VStack(alignment: .leading) { ForEach(matches.prefix(8)) { Text("\($0.date) · \($0.rawDescription) · \(Money.display($0.amount))").font(.caption) } } }.frame(height: 100)
            }
            Toggle("Apply all rules after saving", isOn: $applyNow)
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save rule") {
                var saved = rule
                if saved.stage == .transfer { saved.type = .transfer; saved.customType = nil }
                if saved.stage == .refund { saved.type = .refund; saved.customType = nil }
                store.change("Save categorization rule") { w in if let i = w.rules.firstIndex(where: { $0.id == saved.id }) { w.rules[i] = saved } else { w.rules.append(saved) }; if applyNow { w.applyRules() } }; dismiss()
            }.buttonStyle(.borderedProminent).disabled(!previewed || rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty || rule.name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding(24).frame(width: 720).onChange(of: rule) { _, _ in previewed = false }
    }
}
struct ReportsView: View {
    @Bindable var store: AppStore
    @State private var month = String(Day.today.prefix(7))
    var entries: [Entry] { store.workspace.entries.filter { $0.reviewed && $0.type != .transfer && $0.date.hasPrefix(month) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Monthly overview").font(.title2.bold())
                HStack { TextField("Month (YYYY-MM)", text: $month).frame(width: 160); Text("Reviewed transactions only · Transfers excluded").font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 16) {
                    metric("Money received", value: entries.filter { store.workspace.incoming($0) > 0 }.reduce(0) { $0 + store.workspace.incoming($1) })
                    metric("Money paid", value: entries.filter { store.workspace.incoming($0) < 0 }.reduce(0) { $0 - store.workspace.incoming($1) })
                    metric("Invoices outstanding", value: store.workspace.invoices.reduce(0) { $0 + store.workspace.outstanding($1) })
                }
                GroupBox("Net expenses by category") {
                    VStack(spacing: 10) {
                        ForEach(store.workspace.categories, id: \.self) { category in
                            let total = entries.filter { $0.category == category && (store.workspace.incoming($0) < 0 || $0.type == .refund) }.reduce(Int64(0)) { $0 - store.workspace.incoming($1) }
                            if total != 0 { HStack { Text(category); Spacer(); Text(Money.display(total)).monospacedDigit() } }
                        }
                    }.padding(12).frame(maxWidth: .infinity)
                }
                GroupBox("Outstanding invoices") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.workspace.invoices.filter { store.workspace.outstanding($0) > 0 }) { invoice in HStack { Text(invoice.number); Text(invoice.client).foregroundStyle(.secondary); Spacer(); Text(store.workspace.invoiceStatus(invoice)); Text(Money.display(store.workspace.outstanding(invoice))).monospacedDigit() } }
                        if store.workspace.invoices.isEmpty { Text("Import an invoice register to see outstanding balances.").foregroundStyle(.secondary) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("These are cash-movement and invoice reports, not a profit and loss statement or a double-entry ledger. Unidentified deposits remain unclassified.").font(.caption).foregroundStyle(.secondary)
                GroupBox("Recent activity") { VStack(alignment: .leading, spacing: 6) { ForEach(store.workspace.audit.suffix(12).reversed()) { record in HStack { Text(record.date, style: .date); Text(record.date, style: .time); Text(record.action) }.font(.caption) } }.padding(10).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(24)
        }
    }
    func metric(_ label: String, value: Int64) -> some View { VStack(alignment: .leading, spacing: 10) { Text(label).font(.caption).foregroundStyle(.secondary); Text(Money.display(value)).font(.title2.bold()).monospacedDigit() }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12)) }
}
