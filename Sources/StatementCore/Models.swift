import Foundation

public enum Bank: String, Codable, CaseIterable, Identifiable, Sendable {
    case hsbc = "HSBC", boc = "Bank of China (Hong Kong)", unknown = "Unknown"
    public var id: String { rawValue }
}
public enum AccountKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bank = "Bank", creditCard = "Credit card"
    public var id: String { rawValue }
}
public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var bank: Bank
    public var kind: AccountKind
    public init(name: String, bank: Bank, kind: AccountKind) { self.name = name; self.bank = bank; self.kind = kind }
}
public struct SourceRegion: Codable, Equatable, Sendable {
    public var page: Int
    public var x: Double, y: Double, width: Double, height: Double
    public init(page: Int, rect: CGRect) { self.page = page; x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
public enum TransactionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown = "Unclassified", purchase = "Purchase", clientPayment = "Client payment", chequeDeposit = "Cheque deposit", transfer = "Transfer", refund = "Refund", fee = "Bank fee"
    case bankTransfer = "Bank transfer", eCheque = "eCheque", charge = "Charge"
    public var displayTitle: String {
        switch self {
        case .clientPayment: return "Clients’ Payment"
        case .chequeDeposit: return "Cheque Deposit"
        case .bankTransfer: return "Bank Transfer"
        case .transfer: return "Internal Transfer"
        case .purchase: return "Expense"
        default: return rawValue
        }
    }
    public var id: String { rawValue }
}
public struct Entry: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var statementID: UUID
    public var accountID: UUID
    public var date: String
    public var amount: Int64 // Bank: inflow positive. Card: charges positive (amount owed).
    public var rawDescription: String
    public var payee = ""
    public var chequeReference = ""
    public var invoiceReference = ""
    public var bankReference = ""
    public var runningBalance: Int64?
    public var category = "Uncategorized"
    public var customType: String?
    public var typeTitle: String { customType ?? type.displayTitle }
    public var type: TransactionType = .unknown
    public var source: SourceRegion?
    public var usedOCR = false
    public var reviewed = false
    public var manuallyEdited = false
    public var duplicateCandidate = false
    public var ruleID: UUID?
    public var referenceSummary: String {
        [("Invoice", invoiceReference), ("Cheque", chequeReference), ("Bank", bankReference)]
            .filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: " · ")
    }
    public var notes = ""
    public init(statementID: UUID, accountID: UUID, date: String, amount: Int64, description: String) {
        self.statementID = statementID; self.accountID = accountID; self.date = date; self.amount = amount; rawDescription = description
    }
}
public struct Statement: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var accountID: UUID
    public var filename: String
    public var storedFilename: String
    public var hash: String
    public var periodStart = ""
    public var periodEnd = ""
    public var openingBalance: Int64?
    public var closingBalance: Int64?
    public var profile = "Unknown"
    public var parserVersion = "0.1-unvalidated"
    /// Set when the user explicitly kept an import with no extracted rows; automatic recovery skips it.
    public var manualEntry: Bool?
    public var warnings: [String] = []
    public var reconciled = false
    public var importedAt = Date()
    public init(accountID: UUID, filename: String, storedFilename: String, hash: String) {
        self.accountID = accountID; self.filename = filename; self.storedFilename = storedFilename; self.hash = hash
    }
}
public struct Invoice: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var number: String
    public var client: String
    public var aliases = ""
    public var date: String
    public var dueDate = ""
    public var total: Int64
    public var startingOutstanding: Int64
    public init(number: String, client: String, date: String, total: Int64, outstanding: Int64) {
        self.number = number; self.client = client; self.date = date; self.total = total; startingOutstanding = outstanding
    }
}
public struct Allocation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var entryID: UUID
    public var invoiceID: UUID
    public var amount: Int64
    public var createdAt = Date()
    public init(entryID: UUID, invoiceID: UUID, amount: Int64) { self.entryID = entryID; self.invoiceID = invoiceID; self.amount = amount }
}
public enum RuleDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case any = "Any", incoming = "Incoming", outgoing = "Outgoing"
    public var id: String { rawValue }
}
public enum RuleStage: Int, Codable, CaseIterable, Identifiable, Sendable {
    case transfer = 0, refund = 1, specific = 2, general = 3
    public var id: Int { rawValue }
    public var title: String { ["Confirmed transfer", "Refund / reversal", "Specific merchant / client", "General description"][rawValue] }
}
public struct CategoryRule: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = "New rule"
    public var enabled = true
    public var stage: RuleStage = .specific
    public var priority = 10
    public var accountID: UUID?
    public var direction: RuleDirection = .outgoing
    public var pattern = ""
    public var category = "Uncategorized"
    public var customType: String?
    public var type: TransactionType = .purchase
    public init() {}
}
public struct InvoiceBatch: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var filename: String
    public var createdAt = Date()
    public var insertedIDs: [UUID]
    public var previous: [Invoice]
    public init(filename: String, insertedIDs: [UUID], previous: [Invoice]) { self.filename = filename; self.insertedIDs = insertedIDs; self.previous = previous }
}
public struct EntryRevision: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var changedAt = Date()
    public var previous: Entry
    public init(previous: Entry) { self.previous = previous }
}
public struct AuditRecord: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var action: String
    public init(_ action: String) { self.action = action }
}
public struct Workspace: Codable, Equatable, Sendable {
    public var customTypes: [String]?
    public var schemaVersion = 1
    public var businessName = ""
    public var accounts: [Account] = []
    public var statements: [Statement] = []
    public var entries: [Entry] = []
    public var invoices: [Invoice] = []
    public var allocations: [Allocation] = []
    public var rules: [CategoryRule] = []
    public var invoiceBatches: [InvoiceBatch] = []
    public var invoiceMapping: [String: Int] = [:]
    public var audit: [AuditRecord] = []
    public var revisions: [EntryRevision] = []
    public var categories = ["Uncategorized", "Office supplies", "Software", "Telecoms", "Travel", "Meals", "Rent", "Utilities", "Professional fees", "Bank fees", "Client receipts"]
    public init() {}
    public func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
    public func outstanding(_ invoice: Invoice) -> Int64 { invoice.startingOutstanding - allocations.filter { $0.invoiceID == invoice.id }.reduce(0) { $0 + $1.amount } }
    public func allocated(_ entryID: UUID) -> Int64 { allocations.filter { $0.entryID == entryID }.reduce(0) { $0 + $1.amount } }
    public func incoming(_ entry: Entry) -> Int64 { account(entry.accountID)?.kind == .creditCard ? -entry.amount : entry.amount }
    public func invoiceStatus(_ invoice: Invoice, today: String = Day.today) -> String {
        let remaining = outstanding(invoice)
        if remaining == 0 { return "Paid" }
        if !invoice.dueDate.isEmpty && invoice.dueDate < today { return "Overdue" }
        return remaining < invoice.total ? "Partially paid" : "Unpaid"
    }
    public func reconciliationDifference(_ statement: Statement) -> Int64? {
        guard let opening = statement.openingBalance, let closing = statement.closingBalance else { return nil }
        return opening + entries.filter { $0.statementID == statement.id }.reduce(0) { $0 + $1.amount } - closing
    }
}
public enum LedgerError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
public enum Money {
    public static func parse(_ text: String) throws -> Int64 {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var negative = false
        if value.hasSuffix("CR") { negative = true; value = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        if value.hasSuffix("DR") { value = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        if value.hasPrefix("(") && value.hasSuffix(")") { negative = true; value = String(value.dropFirst().dropLast()) }
        for symbol in ["HKD", "HK$", "$", ","] { value = value.replacingOccurrences(of: symbol, with: "") }
        value = value.trimmingCharacters(in: .whitespaces)
        guard value.range(of: #"^[+-]?\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), abs(decimal) <= Decimal(1_000_000_000_000 as Int64) else {
            throw LedgerError.invalid("Enter a valid HKD amount with no more than two decimal places.")
        }
        let cents = NSDecimalNumber(decimal: decimal * 100).int64Value
        return negative ? -abs(cents) : cents
    }
    public static func plain(_ cents: Int64) -> String { String(format: "%@%lld.%02lld", cents < 0 ? "-" : "", abs(cents) / 100, abs(cents) % 100) }
    public static func signed(_ cents: Int64) -> String { (cents > 0 ? "+" : "") + plain(cents) }
    public static func display(_ cents: Int64) -> String { "HK$ " + plain(cents) }
}
public enum Day {
    public static var today: String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Asia/Hong_Kong"); return f.string(from: Date()) }
    public static func valid(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let date = f.date(from: value) else { return false }; return f.string(from: date) == value
    }
    public static func parse(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if valid(value) { return value }
        for format in ["d/M/yyyy", "d-M-yyyy", "d-MMM-yyyy", "d MMM yyyy", "yyyy/M/d", "yyyy年M月d日"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 0); f.isLenient = false; f.dateFormat = format
            if let date = f.date(from: value) { f.dateFormat = "yyyy-MM-dd"; return f.string(from: date) }
        }
        throw LedgerError.invalid("Use an ISO date (YYYY-MM-DD) or a day/month/year date.")
    }
}
