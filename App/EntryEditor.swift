import SwiftUI
import StatementCore

struct EntryEditor: View {
    @Bindable var store: AppStore
    let original: Entry
    @Environment(\.dismiss) private var dismiss
    @State private var entry: Entry
    @State private var amount: String
    @State private var confirmedDuplicate = false
    @State private var message: String?
    init(store: AppStore, original: Entry) { self.store = store; self.original = original; _entry = State(initialValue: original); _amount = State(initialValue: Money.plain(original.amount)) }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review transaction").font(.title2.bold())
            Text("Compare the date, amount, sign, and identifiers with the source PDF.").foregroundStyle(.secondary)
            HStack { TextField("Date (YYYY-MM-DD)", text: $entry.date); TextField("Amount in HKD", text: $amount) }
            Text(store.workspace.account(entry.accountID)?.kind == .creditCard ? "Positive = charge; negative = repayment or credit." : "Positive = money received; negative = money paid.").font(.caption).foregroundStyle(.secondary)
            TextField("Original description", text: $entry.rawDescription, axis: .vertical).lineLimit(2...4)
            TextField("Payee / client", text: $entry.payee)
            ClassificationFields(store: store, type: $entry.type, customType: $entry.customType, category: $entry.category)
            HStack { TextField("Invoice reference", text: $entry.invoiceReference); TextField("Cheque reference", text: $entry.chequeReference) }
            TextField("Bank reference", text: $entry.bankReference)
            TextField("Review notes", text: $entry.notes, axis: .vertical).lineLimit(2...3)
            if entry.usedOCR { Label("OCR-derived row: verify numbers and references carefully.", systemImage: "text.viewfinder").foregroundStyle(.orange).font(.caption) }
            if original.duplicateCandidate { Toggle("This is a legitimate separate transaction, not a duplicate", isOn: $confirmedDuplicate) }
            if let balance = entry.runningBalance { Text("Extracted running balance: \(Money.display(balance))").font(.caption).foregroundStyle(.secondary) }
            if !store.workspace.revisions.filter({ $0.previous.id == entry.id }).isEmpty {
                DisclosureGroup("Previous corrections") {
                    ForEach(store.workspace.revisions.filter { $0.previous.id == entry.id }.suffix(5).reversed()) { revision in
                        Text("\(revision.previous.date) · \(Money.display(revision.previous.amount)) · \(revision.previous.rawDescription)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            AISuggestionPanel(settings: store.ai, description: entry.rawDescription, direction: aiDirection, categories: store.workspace.categories) { suggestion in
                entry.customType = nil; entry.category = suggestion.category; entry.type = suggestion.transactionType; entry.reviewed = false
                entry.notes += (entry.notes.isEmpty ? "" : "\n") + "AI category suggestion accepted (\(DeepSeekClient.model)); verify against source."
            }
            Toggle("Reviewed against the original statement", isOn: $entry.reviewed)
            if let message { Text(message).foregroundStyle(.red) }
            HStack {
                if store.workspace.entries.contains(where: { $0.id == original.id }) {
                    Button("Remove row", role: .destructive) {
                        store.error = nil
                        store.change("Remove transaction") { try $0.removeEntry(entry.id) }
                        if let error = store.error { message = error; store.error = nil } else { dismiss() }
                    }
                }
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.borderedProminent)
            }
        }.padding(24)
        }.frame(width: 760, height: 760)
    }
    var aiDirection: RuleDirection {
        guard let value = try? Money.parse(amount), value != 0 else { return .any }
        let flow = store.workspace.account(entry.accountID)?.kind == .creditCard ? -value : value
        return flow > 0 ? .incoming : .outgoing
    }
    func save() {
        do {
            entry.date = try Day.parse(entry.date); entry.amount = try Money.parse(amount)
            guard !entry.rawDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerError.invalid("Enter a transaction description.") }
            if original.duplicateCandidate && entry.reviewed && !confirmedDuplicate { throw LedgerError.invalid("Resolve the possible duplicate before marking this row reviewed.") }
            if confirmedDuplicate { entry.duplicateCandidate = false }
            if entry.type == .transfer { entry.category = "Uncategorized" }
            store.error = nil; store.saveEntry(entry)
            if store.error == nil { dismiss() } else { message = store.error; store.error = nil }
        } catch { message = error.localizedDescription }
    }
}

struct ClassificationFields: View {
    @Bindable var store: AppStore
    @Binding var type: TransactionType
    @Binding var customType: String?
    @Binding var category: String
    private enum ItemKind: String, Identifiable { case type, category; var id: String { rawValue } }
    @State private var adding: ItemKind?
    @State private var name = ""
    @State private var error: String?
    private var typeSelection: Binding<String> {
        Binding(get: { customType.map { "custom:" + $0 } ?? "builtin:" + type.rawValue }, set: { value in
            if value.hasPrefix("custom:") { customType = String(value.dropFirst(7)); type = .unknown }
            else if let builtIn = TransactionType(rawValue: String(value.dropFirst(8))) { type = builtIn; customType = nil }
        })
    }
    private var customNames: [String] { Array(Set((store.workspace.customTypes ?? []) + (customType.map { [$0] } ?? []))).sorted() }
    private var categoryNames: [String] { Array(Set(store.workspace.categories + [category])).sorted() }
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading) {
                Picker("Type", selection: typeSelection) {
                    ForEach(TransactionType.allCases) { Text($0.displayTitle).tag("builtin:" + $0.rawValue) }
                    ForEach(customNames, id: \.self) { Text($0).tag("custom:" + $0) }
                }
                Button("Add type…", systemImage: "plus") { begin(isType: true) }
            }
            VStack(alignment: .leading) {
                Picker("Category", selection: $category) { ForEach(categoryNames, id: \.self) { Text($0).tag($0) } }
                Button("Add category…", systemImage: "plus") { begin(isType: false) }
            }
        }
        .sheet(item: $adding) { kind in
            VStack(alignment: .leading, spacing: 16) {
                Text(kind == .type ? "Add type" : "Add category").font(.title2.bold())
                Text("This item will be saved to your workspace for future transactions and rules.").foregroundStyle(.secondary)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit { add(isType: kind == .type) }
                if let error { Text(error).foregroundStyle(.red) }
                HStack { Button("Cancel") { adding = nil }.keyboardShortcut(.cancelAction); Spacer(); Button("Add") { add(isType: kind == .type) }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 420)
        }
    }
    private func begin(isType: Bool) { name = ""; error = nil; adding = isType ? .type : .category }
    private func add(isType: Bool) {
        var added = ""
        store.error = nil
        store.change(isType ? "Add transaction type" : "Add expense category") { workspace in
            added = try workspace.addClassificationItem(name, isType: isType)
        }
        if let failure = store.error { error = failure; store.error = nil; return }
        if isType { customType = added; type = .unknown } else { category = added }
        adding = nil
    }
}
