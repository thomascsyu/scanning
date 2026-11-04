import Foundation

public extension Workspace {
    mutating func allocate(entryID: UUID, invoiceID: UUID, amount: Int64) throws {
        guard let entry = entries.first(where: { $0.id == entryID }), let invoice = invoices.first(where: { $0.id == invoiceID }) else { throw LedgerError.invalid("Payment or invoice no longer exists.") }
        guard account(entry.accountID)?.kind == .bank, entry.reviewed, entry.type != .transfer, entry.type != .refund,
              amount > 0, amount <= entry.amount - allocated(entryID), amount <= outstanding(invoice) else {
            throw LedgerError.invalid("Use a reviewed incoming bank payment. The allocation cannot exceed the unallocated payment or invoice balance.")
        }
        allocations.append(Allocation(entryID: entryID, invoiceID: invoiceID, amount: amount))
    }
    func suggestions(for entry: Entry) -> [Invoice] {
        guard incoming(entry) > 0, entry.type != .transfer, entry.type != .refund else { return [] }
        func score(_ invoice: Invoice) -> Int {
            var result = 0
            if !entry.invoiceReference.isEmpty && InvoiceReference.matches(entry.invoiceReference, invoice.number) { result += 100 }
            let haystack = (entry.rawDescription + " " + entry.payee).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let names = [invoice.client] + invoice.aliases.components(separatedBy: ";")
            if names.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && haystack.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }) { result += 20 }
            if outstanding(invoice) == incoming(entry) - allocated(entry.id) { result += 10 }
            return result
        }
        return invoices.filter { outstanding($0) > 0 && score($0) > 0 }.sorted { score($0) > score($1) }
    }
    mutating func removeStatement(_ id: UUID) {
        let ids = Set(entries.filter { $0.statementID == id }.map(\.id))
        allocations.removeAll { ids.contains($0.entryID) }
        entries.removeAll { $0.statementID == id }
        statements.removeAll { $0.id == id }
    }
    /// Replace or add a statement and its parsed rows, then re-run duplicate detection and rules.
    mutating func commitParsedStatement(_ statement: Statement, parseResult: ParseResult) throws {
        removeStatement(statement.id)
        statements.append(statement)
        entries.append(contentsOf: parseResult.entries)
        flagDuplicates()
        applyRules()
        try validate()
    }
    mutating func importInvoices(_ incoming: [Invoice], filename: String) throws {
        var next = self
        var inserted: [UUID] = [], previous: [Invoice] = []
        var seen = Set<String>()
        for var invoice in incoming {
            let key = invoice.number.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !key.isEmpty, seen.insert(key).inserted else { throw LedgerError.invalid("Invoice numbers must be nonempty and unique within an import.") }
            if let index = next.invoices.firstIndex(where: { $0.number.uppercased() == key }) {
                let old = next.invoices[index]
                guard old.client.caseInsensitiveCompare(invoice.client) == .orderedSame else { throw LedgerError.invalid("An existing invoice number belongs to a different client. Review the source register.") }
                let applied = next.allocations.filter { $0.invoiceID == old.id }.reduce(0) { $0 + $1.amount }
                guard invoice.startingOutstanding >= applied else { throw LedgerError.invalid("Updated starting balance is below allocations already recorded here. Import the original baseline, not a current balance that already includes these payments.") }
                previous.append(old); invoice.id = old.id; invoice.aliases = old.aliases; next.invoices[index] = invoice
            } else { inserted.append(invoice.id); next.invoices.append(invoice) }
        }
        next.invoiceBatches.append(InvoiceBatch(filename: filename, insertedIDs: inserted, previous: previous))
        try next.validate(); self = next
    }
    mutating func rollbackLatestInvoiceBatch() throws {
        guard let batch = invoiceBatches.last else { return }
        let inserted = Set(batch.insertedIDs)
        guard !allocations.contains(where: { inserted.contains($0.invoiceID) }) else { throw LedgerError.invalid("Reverse allocations on invoices created by this batch before rolling it back.") }
        var next = self
        next.invoices.removeAll { inserted.contains($0.id) }
        for old in batch.previous { if let i = next.invoices.firstIndex(where: { $0.id == old.id }) { next.invoices[i] = old } }
        next.invoiceBatches.removeLast()
        try next.validate(); self = next
    }
    mutating func flagDuplicates() {
        for i in entries.indices {
            let entry = entries[i]
            // Do not collapse repeated transactions within a single statement.
            let duplicate = entries.contains { other in
                other.id != entry.id && other.statementID != entry.statementID && other.accountID == entry.accountID && other.date == entry.date && other.amount == entry.amount &&
                other.rawDescription.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(entry.rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
            if duplicate && !entries[i].reviewed { entries[i].duplicateCandidate = true }
        }
    }
    func ruleMatches(_ rule: CategoryRule, _ entry: Entry) -> Bool {
        guard rule.enabled, !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rule.accountID == nil || rule.accountID == entry.accountID else { return false }
        let flow = incoming(entry)
        if rule.direction == .incoming && flow <= 0 { return false }
        if rule.direction == .outgoing && flow >= 0 { return false }
        return entry.rawDescription.localizedCaseInsensitiveContains(rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    mutating func applyRules() {
        for index in entries.indices {
            guard !entries[index].manuallyEdited, !entries[index].reviewed else { continue }
            let matches = rules.filter { ruleMatches($0, entries[index]) }.sorted { ($0.stage.rawValue, $0.priority) < ($1.stage.rawValue, $1.priority) }
            entries[index].customType = nil; entries[index].ruleID = nil; entries[index].category = "Uncategorized"; entries[index].type = .unknown
            entries[index].extractReferences()
            entries[index].type = entries[index].suggestedType(incoming: incoming(entries[index]))
            guard let first = matches.first else { continue }
            let peers = matches.filter { $0.stage == first.stage && $0.priority == first.priority }
            guard peers.allSatisfy({ $0.type == first.type && $0.customType == first.customType && $0.category == first.category }) else { entries[index].type = .unknown; continue }
            entries[index].category = first.type == .transfer ? "Uncategorized" : first.category
            entries[index].customType = first.customType; entries[index].type = first.type; entries[index].ruleID = first.id
        }
    }
    func validate() throws {
        guard schemaVersion == 1 else { throw LedgerError.invalid("This workspace version is not supported.") }
        func unique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
        guard unique(accounts.map(\.id)), unique(statements.map(\.id)), unique(entries.map(\.id)), unique(invoices.map(\.id)), unique(allocations.map(\.id)), unique(invoices.map { $0.number.uppercased() }) else { throw LedgerError.invalid("Duplicate record identifiers were found.") }
        let limit: Int64 = 100_000_000_000_000
        // Bound untrusted backup values before any totals, so malformed data cannot overflow Int64.
        guard entries.count <= 50_000, allocations.count <= 50_000, invoices.count <= 50_000,
              entries.allSatisfy({ $0.amount >= -limit && $0.amount <= limit }),
              allocations.allSatisfy({ $0.amount > 0 && $0.amount <= limit }),
              invoices.allSatisfy({ $0.total >= 0 && $0.total <= limit && $0.startingOutstanding >= 0 && $0.startingOutstanding <= $0.total }) else {
            throw LedgerError.invalid("Workspace exceeds supported record or monetary limits (50,000 transactions, invoices, or allocations).")
        }
        for statement in statements {
            guard account(statement.accountID) != nil, statement.storedFilename == URL(fileURLWithPath: statement.storedFilename).lastPathComponent, !statement.storedFilename.isEmpty else { throw LedgerError.invalid("Invalid statement account or document path.") }
            if let opening = statement.openingBalance, opening < -limit || opening > limit { throw LedgerError.invalid("Statement balance is too large.") }
            if let closing = statement.closingBalance, closing < -limit || closing > limit { throw LedgerError.invalid("Statement balance is too large.") }
            if statement.reconciled && (reconciliationDifference(statement) != 0 || entries.contains { $0.statementID == statement.id && (!$0.reviewed || $0.duplicateCandidate) }) { throw LedgerError.invalid("A reconciled statement must balance and have every transaction reviewed.") }
        }
        for entry in entries {
            guard Day.valid(entry.date), entry.amount >= -limit, entry.amount <= limit,
                  let statement = statements.first(where: { $0.id == entry.statementID }), statement.accountID == entry.accountID else { throw LedgerError.invalid("A transaction has an invalid date, amount, or statement account.") }
            let used = allocated(entry.id)
            if used > 0 && (!entry.reviewed || account(entry.accountID)?.kind != .bank || entry.type == .transfer || entry.type == .refund || used > entry.amount) { throw LedgerError.invalid("Reverse payment allocations before changing this payment's amount, type, or review status.") }
        }
        for invoice in invoices {
            guard !invoice.number.trimmingCharacters(in: .whitespaces).isEmpty, !invoice.client.trimmingCharacters(in: .whitespaces).isEmpty,
                  Day.valid(invoice.date), invoice.dueDate.isEmpty || Day.valid(invoice.dueDate), invoice.total >= 0, invoice.total <= limit,
                  invoice.startingOutstanding >= 0, invoice.startingOutstanding <= invoice.total, outstanding(invoice) >= 0 else { throw LedgerError.invalid("Invoice dates or amounts are invalid. Outstanding must be between zero and the original total, and cover existing allocations.") }
        }
        for item in allocations {
            guard item.amount > 0, item.amount <= limit, entries.contains(where: { $0.id == item.entryID }), invoices.contains(where: { $0.id == item.invoiceID }) else { throw LedgerError.invalid("Invalid payment allocation.") }
        }
    }
}

public extension Entry {
    mutating func extractReferences() {
        func capture(_ pattern: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: rawDescription, range: NSRange(rawDescription.startIndex..., in: rawDescription)),
                  let range = Range(match.range(at: 1), in: rawDescription) else { return "" }
            return String(rawDescription[range])
        }
        if invoiceReference.isEmpty { invoiceReference = capture(#"\b(INV[-/]?[0-9][A-Z0-9/-]*)\b"#)
            if invoiceReference.isEmpty { invoiceReference = capture(#"(?:INVOICE|發票|发票)[\s:#-]*([A-Z0-9]*[0-9][A-Z0-9/-]*)"#) }
        }
        if chequeReference.isEmpty { chequeReference = capture(#"(?:E[- ]?CHEQUE|CHEQUE|CHECK|CHQ|支票)[\s:#-]*([0-9]+)"#) }
        if bankReference.isEmpty { bankReference = capture(#"(?:\bREF(?:ERENCE)?|參考編號|参考编号)[\s:#-]*([A-Z0-9]*[0-9][A-Z0-9/-]*)"#) }
    }
    func suggestedType(incoming: Int64) -> TransactionType {
        let text = rawDescription.lowercased()
        func has(_ terms: [String]) -> Bool { terms.contains { text.contains($0) } }
        if incoming > 0 {
            if has(["refund", "退款", "退回款項"]) { return .refund }
            if has(["cheque deposit", "check deposit", "存入支票", "支票存款"]) { return .chequeDeposit }
            if has(["client payment", "customer payment", "客戶付款", "客户付款"]) { return .clientPayment }
        } else if incoming < 0 {
            if has(["echeque", "e-cheque", "e cheque", "電子支票", "电子支票"]) { return .eCheque }
            if has(["bank fee", "service charge", "銀行收費", "銀行手續費"]) { return .fee }
            if has(["charge", "收費"]) { return .charge }
            if has(["purchase", "購物", "消費"]) { return .purchase }
        }
        if incoming != 0 && has(["bank transfer", "fund transfer", "funds transfer", "銀行轉賬", "轉帳", "轉賬", "轉數快"]) { return .bankTransfer }
        return .unknown
    }
}

public extension Workspace {
    mutating func addClassificationItem(_ name: String, isType: Bool) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 80, cleaned.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LedgerError.invalid("Enter a name of 1–80 characters on a single line.")
        }
        let existing = isType ? TransactionType.allCases.flatMap { [$0.rawValue, $0.displayTitle] } + (customTypes ?? []) : categories
        guard !existing.contains(where: { $0.compare(cleaned, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw LedgerError.invalid("That name already exists. Choose it from the list.")
        }
        if isType { customTypes = (customTypes ?? []) + [cleaned] } else { categories.append(cleaned) }
        return cleaned
    }
}

public enum InvoiceReference {
    /// Strip presentation labels, never meaningful prefixes such as INV-00042 or leading zeros.
    public static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: #"^(?:INVOICE|INV|發票|发票)[\s:#：]+"#,
            with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
    public static func matches(_ reference: String, _ number: String) -> Bool {
        let a = normalized(reference), b = normalized(number)
        return !a.isEmpty && a == b
    }
}
