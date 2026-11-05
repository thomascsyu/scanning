import XCTest
import PDFKit
import AppKit
import CryptoKit
@testable import StatementCore

final class StatementCoreTests: XCTestCase {
    func fixture(kind: AccountKind = .bank) -> Workspace {
        var w = Workspace(); w.businessName = "Synthetic test business"
        let a = Account(name: "Test account", bank: .hsbc, kind: kind); w.accounts = [a]
        var s = Statement(accountID: a.id, filename: "Synthetic.pdf", storedFilename: "test.pdf", hash: "test")
        s.periodEnd = "2026-01-31"; w.statements = [s]
        return w
    }
    func entry(_ w: Workspace, amount: Int64 = 10000, description: String = "CLIENT INV-001") -> Entry {
        var e = Entry(statementID: w.statements[0].id, accountID: w.accounts[0].id, date: "2026-01-20", amount: amount, description: description); e.reviewed = true; return e
    }
    func invoice(_ number: String = "INV-001", total: Int64 = 10000) -> Invoice { Invoice(number: number, client: "Example Client", date: "2026-01-01", total: total, outstanding: total) }
    func testStatementFoldersKeepBankAndCreditApart() {
        let bank = Account(name: "Operating", bank: .hsbc, kind: .bank)
        let card = Account(name: "Card", bank: .hsbc, kind: .creditCard)
        var older = Statement(accountID: bank.id, filename: "Older.pdf", storedFilename: "o.pdf", hash: "o")
        older.importedAt = Date(timeIntervalSince1970: 100)
        var newer = Statement(accountID: bank.id, filename: "Newer.pdf", storedFilename: "n.pdf", hash: "n")
        newer.importedAt = Date(timeIntervalSince1970: 200)
        let cardStatement = Statement(accountID: card.id, filename: "Card.pdf", storedFilename: "c.pdf", hash: "c")
        let bankEntry = Entry(statementID: newer.id, accountID: bank.id, date: "2026-01-02", amount: -100, description: "Rent")
        let cardEntry = Entry(statementID: cardStatement.id, accountID: card.id, date: "2026-01-03", amount: 200, description: "Software")
        var workspace = Workspace()
        workspace.accounts = [bank, card]
        workspace.statements = [older, cardStatement, newer]
        workspace.entries = [cardEntry, bankEntry]
        XCTAssertEqual(workspace.statements(in: .bank).map(\.filename), ["Newer.pdf", "Older.pdf"])
        XCTAssertEqual(workspace.statements(in: .creditCard).map(\.filename), ["Card.pdf"])
        XCTAssertEqual(workspace.entries(in: .bank).map(\.id), [bankEntry.id])
        XCTAssertEqual(workspace.entries(in: .creditCard).map(\.id), [cardEntry.id])
    }
    func testMoneyRoundTripAndSigns() throws {
        for (input, expected): (String, Int64) in [("HK$ 1,234.56",123456),("(12.34)",-1234),("25.00 CR",-2500),("25.00 DR",2500),("-0.01",-1)] { XCTAssertEqual(try Money.parse(input), expected); XCTAssertEqual(try Money.parse(Money.plain(expected)), expected) }
        for invalid in ["1.234", "", "NaN", "12abc", "1e6", "999999999999999999999999999"] { XCTAssertThrowsError(try Money.parse(invalid)) }
    }
    func testCalendarAndYearBoundary() throws {
        XCTAssertTrue(Day.validMonth("2026-01")); XCTAssertTrue(Day.validMonth("2024-02"))
        XCTAssertFalse(Day.validMonth("2026-13")); XCTAssertFalse(Day.validMonth("26-01")); XCTAssertFalse(Day.validMonth("2026/01"))
        XCTAssertFalse(Day.valid("2026-02-30")); XCTAssertTrue(Day.valid("2024-02-29"))
        XCTAssertEqual(try Day.parse("31/01/2026"), "2026-01-31")
        XCTAssertEqual(StatementParser.transactionDate("31 Dec", end: "2026-01-31"), "2025-12-31")
        XCTAssertEqual(StatementParser.transactionDate("2/1", end: "2026-01-31"), "2026-01-02")
    }
    func testCSVQuotedMultilineChineseAndTrailingCells() throws {
        let parsed = try CSV.read("\u{FEFF}a,b,c\r\n\"中文,客戶\",\"two\"\"quotes\nline\",\r\n")
        XCTAssertEqual(parsed[1], ["中文,客戶", "two\"quotes\nline", ""])
        XCTAssertEqual(try CSV.read(CSV.write(parsed)), parsed)
        XCTAssertThrowsError(try CSV.read("a,\"unterminated"))
        XCTAssertThrowsError(try CSV.read("a,\"closed\"oops"))
    }
    func testExportNeutralizesFormulasButKeepsMoneyNumeric() throws {
        let output = try CSV.read(CSV.write([["Text", "Amount"], [" =HYPERLINK(\"x\")", "-12.34"], ["@SUM(A1)", "=2+2"]], numericColumns: [1]))
        XCTAssertTrue(output[1][0].hasPrefix("'")); XCTAssertEqual(output[1][1], "-12.34"); XCTAssertTrue(output[2][1].hasPrefix("'"))
    }
    func testInvoiceMappingLeadingZerosChineseAndDates() throws {
        let sheet = Sheet(name: "test", rows: [["Invoice number","Client","Invoice date","Original total","Starting outstanding","Due date"],["000123","測試客戶","2026-01-01","1,200.50","200.50","2026-02-01"]])
        let invoices = try InvoiceReader.invoices(sheet: sheet, mapping: InvoiceReader.suggestedMapping(headers: sheet.rows[0]))
        XCTAssertEqual(invoices[0].number, "000123"); XCTAssertEqual(invoices[0].startingOutstanding, 20050)
        XCTAssertEqual(invoices[0].client, "測試客戶"); XCTAssertEqual(invoices[0].dueDate, "2026-02-01")
    }
    func testInvoiceMissingColumnsInvalidBalancesAndCurrency() throws {
        let headers = ["Invoice number","Client","Invoice date","Original total","Starting outstanding","Currency"]
        XCTAssertThrowsError(try InvoiceReader.invoices(sheet: Sheet(name: "bad", rows: [headers,["1","Client","2026-01-01","100","120","HKD"]]), mapping: InvoiceReader.suggestedMapping(headers: headers)))
        XCTAssertThrowsError(try InvoiceReader.invoices(sheet: Sheet(name: "bad", rows: [headers,["1","Client","2026-01-01","100","100","USD"]]), mapping: InvoiceReader.suggestedMapping(headers: headers)))
        XCTAssertThrowsError(try InvoiceReader.invoices(sheet: Sheet(name: "bad", rows: [headers]), mapping: [:]))
    }
    func testPartialCombinedExcessAndReverseAllocations() throws {
        var w = fixture(); let e = entry(w, amount: 15000); w.entries = [e]; w.invoices = [invoice("A"), invoice("B")]
        try w.allocate(entryID: e.id, invoiceID: w.invoices[0].id, amount: 10000)
        try w.allocate(entryID: e.id, invoiceID: w.invoices[1].id, amount: 3000)
        XCTAssertEqual(w.outstanding(w.invoices[0]), 0); XCTAssertEqual(w.outstanding(w.invoices[1]), 7000); XCTAssertEqual(e.amount - w.allocated(e.id), 2000)
        XCTAssertThrowsError(try w.allocate(entryID: e.id, invoiceID: w.invoices[1].id, amount: 3000))
        w.allocations.removeFirst(); XCTAssertEqual(w.outstanding(w.invoices[0]), 10000); try w.validate()
    }
    func testMultiplePaymentsAndOverdueStatus() throws {
        var w = fixture(); w.entries = [entry(w, amount: 4000),entry(w, amount: 6000)]; var inv = invoice(); inv.dueDate = "2026-01-10"; w.invoices = [inv]
        try w.allocate(entryID: w.entries[0].id, invoiceID: inv.id, amount: 4000)
        XCTAssertEqual(w.invoiceStatus(inv, today: "2026-01-05"), "Partially paid"); XCTAssertEqual(w.invoiceStatus(inv, today: "2026-01-20"), "Overdue")
        try w.allocate(entryID: w.entries[1].id, invoiceID: inv.id, amount: 6000); XCTAssertEqual(w.invoiceStatus(inv), "Paid")
    }
    func testAllocationsRequireReviewedBankPayment() throws {
        var w = fixture(); var e = entry(w); e.reviewed = false; w.entries = [e]; w.invoices = [invoice()]
        XCTAssertThrowsError(try w.allocate(entryID: e.id, invoiceID: w.invoices[0].id, amount: 100))
        w.entries[0].reviewed = true; w.entries[0].type = .transfer
        XCTAssertThrowsError(try w.allocate(entryID: e.id, invoiceID: w.invoices[0].id, amount: 100))
        w.entries[0].type = .refund
        XCTAssertThrowsError(try w.allocate(entryID: e.id, invoiceID: w.invoices[0].id, amount: 100))
    }
    func testRepeatInvoiceImportPreservesAllocationsAndRollback() throws {
        var w = fixture(); w.entries = [entry(w)]; try w.importInvoices([invoice()], filename: "one.csv")
        let id = w.invoices[0].id
        try w.allocate(entryID: w.entries[0].id, invoiceID: id, amount: 4000)
        var updated = invoice(); updated.dueDate = "2026-03-01"
        try w.importInvoices([updated], filename: "two.csv")
        XCTAssertEqual(w.invoices.count, 1); XCTAssertEqual(w.invoices[0].id, id); XCTAssertEqual(w.outstanding(w.invoices[0]), 6000)
        try w.rollbackLatestInvoiceBatch(); XCTAssertEqual(w.invoices[0].dueDate, "")
        XCTAssertThrowsError(try w.rollbackLatestInvoiceBatch())
        updated.startingOutstanding = 3000; XCTAssertThrowsError(try w.importInvoices([updated], filename: "bad.csv"))
    }
    func testDuplicateInvoiceNumbersRejectedAtomically() throws {
        var w = fixture(); let before = w
        XCTAssertThrowsError(try w.importInvoices([invoice(),invoice()], filename: "duplicate.csv")); XCTAssertEqual(w, before)
    }
    func testCommitParsedStatementAppliesRules() throws {
        var w = fixture()
        var rule = CategoryRule(); rule.name = "Client"; rule.pattern = "CLIENT"; rule.category = "Revenue"; rule.direction = .incoming; rule.type = .clientPayment
        w.rules = [rule]
        let stmt = w.statements[0]
        let row = Entry(statementID: stmt.id, accountID: w.accounts[0].id, date: "2026-01-05", amount: 5000, description: "CLIENT payment")
        let result = ParseResult(entries: [row], warnings: [], profile: "test", openingBalance: 0, closingBalance: 5000)
        try w.commitParsedStatement(stmt, parseResult: result)
        XCTAssertEqual(w.entries.count, 1); XCTAssertEqual(w.entries[0].category, "Revenue")
    }
    func testRulePriorityConflictAndManualPreservation() throws {
        var w = fixture(); var e = entry(w, amount: -2000, description: "ACME SOFTWARE"); e.reviewed = false; w.entries = [e]
        var rule = CategoryRule(); rule.pattern = "ACME"; rule.category = "Software"; w.rules = [rule]; w.applyRules(); XCTAssertEqual(w.entries[0].category, "Software")
        var conflict = rule; conflict.id = UUID(); conflict.category = "Office supplies"; w.rules.append(conflict); w.applyRules(); XCTAssertEqual(w.entries[0].category, "Uncategorized")
        w.rules[1].priority = 20; w.applyRules(); XCTAssertEqual(w.entries[0].category, "Software")
        w.entries[0].manuallyEdited = true; w.entries[0].category = "Travel"; w.applyRules(); XCTAssertEqual(w.entries[0].category, "Travel")
    }
    func testCardDirectionsAndChequeDepositLabels() throws {
        var w = fixture(kind: .creditCard); var e = entry(w, amount: 2000, description: "SOFTWARE"); e.reviewed = false; w.entries = [e]
        var rule = CategoryRule(); rule.pattern = "SOFTWARE"; rule.category = "Software"; rule.direction = .outgoing; w.rules = [rule]; w.applyRules(); XCTAssertEqual(w.entries[0].category, "Software"); XCTAssertEqual(w.incoming(e), -2000)
        var bank = fixture(); var cheque = entry(bank, description: "支票存款 000123"); cheque.reviewed = false; bank.entries = [cheque]; bank.applyRules(); XCTAssertEqual(bank.entries[0].type, .chequeDeposit); XCTAssertEqual(bank.entries[0].category, "Uncategorized")
    }
    func testOverlappingImportsFlagButNeverDeleteLegitimateRepeats() {
        var w = fixture(); var a = entry(w); a.reviewed = false; var b = a; b.id = UUID(); w.entries = [a,b]; w.flagDuplicates(); XCTAssertFalse(w.entries[0].duplicateCandidate)
        var other = w.statements[0]; other.id = UUID(); other.hash = "different"; other.storedFilename = "other.pdf"; w.statements.append(other)
        var c = a; c.id = UUID(); c.statementID = other.id; w.entries.append(c); w.flagDuplicates(); XCTAssertEqual(w.entries.count, 3); XCTAssertTrue(w.entries.allSatisfy(\.duplicateCandidate))
    }
    func testReconciliationAndRollbackRestoreInvoiceBalances() throws {
        var w = fixture(); w.statements[0].openingBalance = 100; w.statements[0].closingBalance = 10100; w.entries = [entry(w)]; w.invoices = [invoice()]
        XCTAssertEqual(w.reconciliationDifference(w.statements[0]), 0); w.statements[0].reconciled = true; try w.validate()
        try w.allocate(entryID: w.entries[0].id, invoiceID: w.invoices[0].id, amount: 10000)
        w.removeStatement(w.statements[0].id); XCTAssertTrue(w.entries.isEmpty); XCTAssertTrue(w.allocations.isEmpty); XCTAssertEqual(w.outstanding(w.invoices[0]), 10000)
    }
    func testReconciliationRejectsUnreviewedAndWrongBalances() throws {
        var w = fixture(); w.entries = [entry(w)]; w.statements[0].openingBalance = 0; w.statements[0].closingBalance = 9999; w.statements[0].reconciled = true
        XCTAssertThrowsError(try w.validate()); w.statements[0].closingBalance = 10000; w.entries[0].reviewed = false; XCTAssertThrowsError(try w.validate())
    }
    func testSuggestionsDoNotAutoAllocate() {
        var w = fixture(); var e = entry(w); e.invoiceReference = "INV-001"; w.entries = [e]; w.invoices = [invoice()]
        XCTAssertEqual(w.suggestions(for: e).count, 1); XCTAssertTrue(w.allocations.isEmpty)
    }
    func testParserUnknownAndAmbiguousRowsStayUnparsed() {
        let w = fixture(); let line = TextLine(text: "01 Jan Unknown payment 100.00 1,000.00", region: SourceRegion(page: 0, rect: CGRect(x: 20,y: 100,width: 300,height: 12)))
        let pdf = ExtractedPDF(lines: [line], hash: "", bank: .unknown, warnings: [])
        XCTAssertTrue(StatementParser.parse(pdf, statementID: w.statements[0].id, account: w.accounts[0], periodEnd: "2026-01-31").entries.isEmpty)
        let known = ExtractedPDF(lines: [line], hash: "", bank: .hsbc, warnings: [])
        XCTAssertTrue(StatementParser.parse(known, statementID: w.statements[0].id, account: w.accounts[0], periodEnd: "2026-01-31").entries.isEmpty)
    }
    func testSyntheticBankAndCardProfilesReferencesAndSigns() {
        for bank in [Bank.hsbc, .boc] {
            for kind in AccountKind.allCases {
                var w = fixture(kind: kind); w.accounts[0].bank = bank
                let text = kind == .bank ? "02 Jan CLIENT INV-0001 100.00 CR" : "02 Jan SHOP 100.00"
                let pdf = ExtractedPDF(lines: [TextLine(text: text, region: SourceRegion(page: 0, rect: CGRect(x: 10,y: 500,width: 400,height: 12)), ocr: true)], hash: "", bank: bank, warnings: [])
                let parsed = StatementParser.parse(pdf, statementID: w.statements[0].id, account: w.accounts[0], periodEnd: "2026-01-31")
                XCTAssertEqual(parsed.entries.count, 1); XCTAssertEqual(parsed.entries.first?.amount, 10000); XCTAssertTrue(parsed.entries.first?.usedOCR == true); XCTAssertFalse(parsed.entries.first?.reviewed ?? true)
                if kind == .bank { XCTAssertEqual(parsed.entries.first?.invoiceReference, "INV-0001") }
            }
        }
    }
    func testPDFExtractionAndPasswordProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let data = NSMutableData(); var box = CGRect(x: 0,y: 0,width: 600,height: 800)
        let consumer = CGDataConsumer(data: data)!, context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil); let graphics = NSGraphicsContext(cgContext: context, flipped: false); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        ("HSBC Synthetic statement for testing only\n02 Jan CLIENT INV-0001 100.00 CR" as NSString).draw(at: CGPoint(x: 40,y: 600), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
        let url = directory.appendingPathComponent("synthetic.pdf"); try (data as Data).write(to: url)
        let result = try PDFExtractor.read(url: url); XCTAssertEqual(result.bank, .hsbc); XCTAssertTrue(result.text.contains("INV-0001")); XCTAssertFalse(result.lines.contains(where: \.ocr))
        let document = PDFDocument(data: data as Data)!
        let protected = directory.appendingPathComponent("protected.pdf")
        XCTAssertTrue(document.write(to: protected, withOptions: [.userPasswordOption: "test-only", .ownerPasswordOption: "owner-only"]))
        XCTAssertThrowsError(try PDFExtractor.read(url: protected)); XCTAssertEqual(try PDFExtractor.read(url: protected, password: "test-only").bank, .hsbc)
    }
    @MainActor func testPersistenceAndBackupRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("Originals"); try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        var w = fixture(); let content = Data("synthetic original".utf8); try content.write(to: originals.appendingPathComponent("test.pdf"))
        w.statements[0].hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined(); w.entries = [entry(w)]; w.invoices = [invoice()]; try w.allocate(entryID: w.entries[0].id, invoiceID: w.invoices[0].id, amount: 2500)
        let database = root.appendingPathComponent("test.store")
        do { let repository = try LedgerRepository(url: database); try repository.save(w); XCTAssertEqual(try repository.load(), w) }
        let reopened = try LedgerRepository(url: database); XCTAssertEqual(try reopened.load(), w)
        let backup = root.appendingPathComponent("test.hkledger"); try WorkspaceBackup.write(w, documents: originals, destination: backup); XCTAssertEqual(try WorkspaceBackup.read(backup), w)
        try Data("tampered".utf8).write(to: backup.appendingPathComponent("Originals/test.pdf")); XCTAssertThrowsError(try WorkspaceBackup.read(backup))
    }

    // MARK: Review fixes

    func secondStatement(_ w: inout Workspace) -> Statement {
        var other = w.statements[0]; other.id = UUID(); other.hash = "different"; other.storedFilename = "other.pdf"; w.statements.append(other); return other
    }
    func testDuplicateFlagsClearWhenOverlappingStatementIsRolledBack() {
        var w = fixture(); var a = entry(w); a.reviewed = false; w.entries = [a]
        let other = secondStatement(&w)
        var c = a; c.id = UUID(); c.statementID = other.id; w.entries.append(c); w.flagDuplicates()
        XCTAssertTrue(w.entries.allSatisfy(\.duplicateCandidate))
        w.removeStatement(other.id)
        XCTAssertEqual(w.entries.count, 1); XCTAssertFalse(w.entries[0].duplicateCandidate)
    }
    func testDuplicateFlagsClearWhenRowIsRemoved() throws {
        var w = fixture(); var a = entry(w); a.reviewed = false; w.entries = [a]
        let other = secondStatement(&w)
        var c = a; c.id = UUID(); c.statementID = other.id; w.entries.append(c); w.flagDuplicates()
        try w.removeEntry(c.id)
        XCTAssertFalse(w.entries[0].duplicateCandidate)
    }
    func testClearOnlyPassKeepsUserConfirmation() {
        var w = fixture(); var a = entry(w); a.reviewed = false; w.entries = [a]
        let other = secondStatement(&w)
        var c = a; c.id = UUID(); c.statementID = other.id; w.entries.append(c); w.flagDuplicates()
        w.entries[0].duplicateCandidate = false // user confirmed it is a separate transaction
        w.flagDuplicates(markNew: false)
        XCTAssertFalse(w.entries[0].duplicateCandidate); XCTAssertTrue(w.entries[1].duplicateCandidate)
    }
    func testRemoveEntryRefusesAllocatedPayment() throws {
        var w = fixture(); w.entries = [entry(w)]; w.invoices = [invoice()]
        try w.allocate(entryID: w.entries[0].id, invoiceID: w.invoices[0].id, amount: 5000)
        XCTAssertThrowsError(try w.removeEntry(w.entries[0].id)); XCTAssertEqual(w.entries.count, 1)
    }
    func testSpreadsheetAmountsRoundFloatingPointArtifacts() throws {
        XCTAssertEqual(try Money.parseSpreadsheet("1320.0000000000002"), 132000)
        XCTAssertEqual(try Money.parseSpreadsheet("99.98999999999999"), 9999)
        XCTAssertEqual(try Money.parseSpreadsheet("1.2E3"), 120000)
        XCTAssertEqual(try Money.parseSpreadsheet("1,200.50"), 120050)
        XCTAssertThrowsError(try Money.parseSpreadsheet("12.345"))
        XCTAssertThrowsError(try Money.parseSpreadsheet("abc"))
    }
    func testInvoiceImportAcceptsFormulaResults() throws {
        let sheet = Sheet(name: "Register", rows: [["Invoice number", "Client", "Invoice date", "Original total", "Starting outstanding"], ["INV-9", "Example Client", "2026-01-01", "1320.0000000000002", "1320.0000000000002"]])
        let invoices = try InvoiceReader.invoices(sheet: sheet, mapping: InvoiceReader.suggestedMapping(headers: sheet.rows[0]))
        XCTAssertEqual(invoices.first?.total, 132000)
    }
    func testCashSummaryDoesNotDoubleCountCardRepayments() {
        var w = Workspace()
        let bank = Account(name: "Bank", bank: .hsbc, kind: .bank), card = Account(name: "Card", bank: .hsbc, kind: .creditCard)
        w.accounts = [bank, card]
        let bs = Statement(accountID: bank.id, filename: "b.pdf", storedFilename: "b.pdf", hash: "b"), cs = Statement(accountID: card.id, filename: "c.pdf", storedFilename: "c.pdf", hash: "c")
        w.statements = [bs, cs]
        func row(_ s: Statement, _ amount: Int64) -> Entry { var e = Entry(statementID: s.id, accountID: s.accountID, date: "2026-03-05", amount: amount, description: "X"); e.reviewed = true; return e }
        // Client pays 1,000; card spends 300; bank pays the 300 card bill; card shows the 300 repayment.
        w.entries = [row(bs, 100_000), row(cs, 30_000), row(bs, -30_000), row(cs, -30_000)]
        let summary = w.cashSummary(month: "2026-03")
        XCTAssertEqual(summary.received, 100_000); XCTAssertEqual(summary.paid, 30_000)
        XCTAssertEqual(summary.cardCharges, 30_000); XCTAssertEqual(summary.cardCredits, 30_000)
        XCTAssertEqual(w.cashSummary(month: "2026-04"), CashSummary())
    }
    func testRenameCategoryValidatesAndUpdatesReferences() throws {
        var w = fixture(); var e = entry(w); e.category = "Software"; w.entries = [e]
        var rule = CategoryRule(); rule.category = "Software"; w.rules = [rule]
        XCTAssertThrowsError(try w.renameCategory("Software", to: "travel"))
        XCTAssertThrowsError(try w.renameCategory("Software", to: "  "))
        XCTAssertThrowsError(try w.renameCategory("Software", to: "Line\nbreak"))
        XCTAssertThrowsError(try w.renameCategory("Uncategorized", to: "Other"))
        try w.renameCategory("Software", to: " SaaS ")
        XCTAssertTrue(w.categories.contains("SaaS")); XCTAssertFalse(w.categories.contains("Software"))
        XCTAssertEqual(w.entries[0].category, "SaaS"); XCTAssertEqual(w.rules[0].category, "SaaS")
        try w.renameCategory("SaaS", to: "saas") // changing only the letter case of the same category is allowed
    }
    func testValidationStillRejectsUnbalancedReconciledStatement() {
        var w = fixture(); w.statements[0].openingBalance = 100; w.statements[0].closingBalance = 999; w.entries = [entry(w)]
        w.statements[0].reconciled = true
        XCTAssertThrowsError(try w.validate())
        w.statements[0].closingBalance = 10100; XCTAssertNoThrow(try w.validate())
        w.entries[0].duplicateCandidate = true; XCTAssertThrowsError(try w.validate())
    }
    func testDuplicateDetectionScalesLinearly() {
        var w = fixture(); let other = secondStatement(&w)
        for i in 0..<20_000 { var e = Entry(statementID: i % 2 == 0 ? w.statements[0].id : other.id, accountID: w.accounts[0].id, date: "2026-01-20", amount: Int64(i), description: "ROW \(i)"); e.reviewed = false; w.entries.append(e) }
        let start = Date(); w.flagDuplicates(); XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertFalse(w.entries.contains(where: \.duplicateCandidate))
    }
    func testUnreferencedOriginalPDFsAreRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = UUID().uuidString + ".pdf", orphan = UUID().uuidString + ".pdf", foreign = "Notes.pdf"
        for name in [kept, orphan, foreign] { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        XCTAssertEqual(OriginalsStore.removeUnreferenced(in: folder, referenced: [kept]), 1)
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertEqual(remaining, [kept, foreign])
    }
}
