import XCTest
@testable import StatementCore

final class ReviewRegressionTests: XCTestCase {
    let account = Account(name: "Synthetic", bank: .hsbc, kind: .bank)
    func cell(_ text: String, _ page: Int, _ x: Double, _ y: Double) -> TextLine {
        TextLine(text: text, region: SourceRegion(page: page, rect: CGRect(x: x, y: y, width: 60, height: 10)))
    }
    func cell(_ text: String, _ x: Double, _ y: Double) -> TextLine { cell(text, 0, x, y) }
    var header: [TextLine] { [cell("Withdrawal", 200, 700), cell("Deposit", 400, 700), cell("Balance", 600, 700)] }
    func parse(_ lines: [TextLine]) -> ParseResult {
        StatementParser.parse(ExtractedPDF(lines: lines, hash: "synthetic", bank: .hsbc, warnings: []), statementID: UUID(), account: account, periodEnd: "2026-05-31")
    }
    var firstRow: [TextLine] { [cell("12 May",0,650),cell("CLIENT A",90,650),cell("10.00",400,650),cell("10.00",600,650)] }
    var nextPage: [TextLine] { [cell("B/F BALANCE",1,0,700),cell("10.00",1,600,700),cell("CLIENT B",1,90,650),cell("20.00",1,400,650),cell("30.00",1,600,650)] }
    func testCarryInKeepsPreviousPageDate() {
        let r = parse(header + firstRow + nextPage)
        XCTAssertEqual(r.entries.map(\.date), ["2026-05-12", "2026-05-12"])
        XCTAssertEqual(r.entries.map(\.amount), [1000,2000])
    }
    func testCarryOutAndCarryInKeepDate() {
        let r = parse(header + firstRow + [cell("C/F BALANCE",0,600),cell("10.00",600,600)] + nextPage)
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertEqual(r.entries.last?.date,"2026-05-12")
    }
    func testFinalClosingDoesNotCarryDateToUndatedRows() {
        let r = parse(header + firstRow + [cell("Closing balance",0,600),cell("10.00",600,600),cell("SUMMARY",90,550),cell("20.00",400,550)])
        XCTAssertEqual(r.entries.count,1)
    }
    func testSamePageOpeningDoesNotInheritDate() {
        let r = parse(header + firstRow + [cell("B/F BALANCE",0,600),cell("10.00",600,600),cell("SUMMARY",90,550),cell("20.00",400,550)])
        XCTAssertEqual(r.entries.count,1)
    }
    func testDatedOpeningRowSuppliesDateForUndatedRows() {
        let r = parse(header + [cell("1 May B/F BALANCE",0,660),cell("100.00",600,660),cell("CLIENT A",90,640),cell("10.00",400,640),cell("110.00",600,640)])
        XCTAssertEqual(r.entries.map(\.date), ["2026-05-01"])
        XCTAssertEqual(r.entries.map(\.amount), [1000])
    }
    func testUnplacedAmountLineIsReported() {
        let r = parse(header + firstRow + [cell("Closing balance",0,600),cell("10.00",600,600),cell("SUMMARY",90,550),cell("20.00",400,550)])
        XCTAssertEqual(r.entries.count,1)
        XCTAssertTrue(r.warnings.contains { $0.contains("1 undated lines with amounts") })
    }
    func testDatedDetailsLineJoinsAmountOnNextLine() {
        let r = parse(header + firstRow + [cell("13 May",0,630),cell("PAYMENT TO ACME",90,630),cell("ACME LTD",90,615),cell("5.00",200,600),cell("5.00",600,600)])
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertEqual(r.entries.last?.date, "2026-05-13")
        XCTAssertEqual(r.entries.last?.amount, -500)
        XCTAssertEqual(r.entries.last?.rawDescription, "PAYMENT TO ACME ACME LTD")
        XCTAssertFalse(r.warnings.contains { $0.contains("use the date printed above") })
    }
    func testRecoverySkipsDeliberateManualEntry() throws {
        var (w,pdf) = recoveryFixture(); w.statements[0].manualEntry = true
        let before = w
        XCTAssertFalse(try w.recoverEmptyImport(statementID:w.statements[0].id,pdf:pdf))
        XCTAssertEqual(w,before)
    }
    func testDecimalInsideDescriptionPreservesInvoice() {
        let r = parse(header + [cell("12 May",0,650),cell("MERCHANT USD12.00 INV-0007",90,650),cell("100.00",200,650),cell("900.00",600,650)])
        XCTAssertEqual(r.entries.first?.rawDescription,"MERCHANT USD12.00 INV-0007")
        XCTAssertEqual(r.entries.first?.invoiceReference,"INV-0007")
        XCTAssertEqual(r.entries.first?.amount,-10000)
    }
    func testInvoiceLabelsMatchPartialPayment() throws {
        let r = parse([cell("12 May CUSTOMER INVOICE 00042 50.00 CR",0,500)])
        var w = Workspace(); w.accounts = [account]; w.entries = r.entries
        w.invoices = [Invoice(number:"00042",client:"Example Ltd",date:"2026-05-01",total:10000,outstanding:10000)]
        XCTAssertEqual(w.suggestions(for: try XCTUnwrap(r.entries.first)).map(\.number),["00042"])
    }
    func testReferenceNormalizationPreservesIdentifiers() {
        for label in ["INVOICE 00042", "Inv 00042", "發票：00042", "00042"] { XCTAssertTrue(InvoiceReference.matches(label,"00042")) }
        XCTAssertFalse(InvoiceReference.matches("00042","42"))
        XCTAssertFalse(InvoiceReference.matches("INV-00042","00042"))
        XCTAssertTrue(InvoiceReference.matches("Invoice: INV-00042","INV-00042"))
        XCTAssertFalse(InvoiceReference.matches("Invoice:",""))
    }
    func testCategoryNamesTrimBeforeDuplicateCheck() throws {
        var w = Workspace(); let original = w.categories
        for name in [" Software ", "software", "\nSoftware\n", " "] { XCTAssertThrowsError(try w.addClassificationItem(name,isType:false)) }
        XCTAssertEqual(w.categories, original)
        XCTAssertEqual(try w.addClassificationItem(" 保險 ",isType:false),"保險")
        XCTAssertThrowsError(try w.addClassificationItem("保險",isType:false))
    }
    func testCustomTypePersistenceAndRules() throws {
        var w = Workspace(); w.accounts = [account]
        XCTAssertEqual(try w.addClassificationItem("Insurance",isType:true),"Insurance")
        XCTAssertThrowsError(try w.addClassificationItem(" insurance ",isType:true))
        var e = Entry(statementID:UUID(),accountID:account.id,date:"2026-05-12",amount:-100,description:"PREMIUM")
        var rule = CategoryRule(); rule.pattern = "PREMIUM"; rule.type = .unknown; rule.customType = "Insurance"
        w.rules = [rule]; w.entries = [e]; w.applyRules(); XCTAssertEqual(w.entries[0].typeTitle,"Insurance")
        e.customType = "Manual"; e.manuallyEdited = true; w.entries = [e]; w.applyRules(); XCTAssertEqual(w.entries[0].typeTitle,"Manual")
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self,from:JSONEncoder().encode(w)),w)
    }
    func testLegacyWorkspaceDecodesWithoutCustomFields() throws {
        let data = try JSONEncoder().encode(Workspace())
        let w = try JSONDecoder().decode(Workspace.self,from:data)
        XCTAssertNil(w.customTypes)
        XCTAssertEqual(try JSONDecoder().decode(TransactionType.self,from:Data("\"Transfer\"".utf8)), .transfer)
    }
    func recoveryFixture() -> (Workspace, ExtractedPDF) {
        var w = Workspace(); w.accounts = [account]
        let statement = Statement(accountID: account.id,filename:"Synthetic.pdf",storedFilename:"synthetic.pdf",hash:"synthetic")
        w.statements = [statement]
        let lines = [cell("Statement date 31 May 2026",0,800),cell("Opening balance 0.00",0,760)] + header + firstRow + [cell("Closing balance 10.00",0,600),cell("Deposits 1 HKD",0,570),cell("Withdrawals 0 HKD",0,540)]
        return (w, ExtractedPDF(lines:lines,hash:"synthetic",bank:.hsbc,warnings:[]))
    }
    func testRecoveryRequiresIndependentCountAndBalance() throws {
        var (w,pdf) = recoveryFixture()
        XCTAssertTrue(try w.recoverEmptyImport(statementID:w.statements[0].id,pdf:pdf))
        XCTAssertEqual(w.entries.count,1); XCTAssertFalse(w.entries[0].reviewed)
        let before = w
        XCTAssertFalse(try w.recoverEmptyImport(statementID:w.statements[0].id,pdf:pdf))
        XCTAssertEqual(w,before)
    }
    func testRecoveryRejectsMismatchedHashAndCount() throws {
        let (original,pdf) = recoveryFixture()
        var w = original; var changed = pdf; changed.hash = "different"
        XCTAssertFalse(try w.recoverEmptyImport(statementID:w.statements[0].id,pdf:changed))
        changed = pdf; changed.lines.removeAll { $0.text == "Deposits 1 HKD" }
        XCTAssertFalse(try w.recoverEmptyImport(statementID:w.statements[0].id,pdf:changed))
        XCTAssertEqual(w,original)
    }
    func testSignedTypeSuggestionsAndReferences() {
        var e = Entry(statementID:UUID(),accountID:account.id,date:"2026-05-12",amount:-100,description:"eCheque 00017 REF:00042")
        e.extractReferences(); XCTAssertEqual(e.chequeReference,"00017"); XCTAssertEqual(e.bankReference,"00042")
        XCTAssertEqual(e.suggestedType(incoming:-100),.eCheque); XCTAssertEqual(e.suggestedType(incoming:100),.unknown)
        e.rawDescription = "Bank transfer"; XCTAssertEqual(e.suggestedType(incoming:100),.bankTransfer); XCTAssertEqual(e.suggestedType(incoming:-100),.bankTransfer)
        XCTAssertEqual(Money.signed(100),"+1.00"); XCTAssertEqual(Money.signed(-100),"-1.00")
    }
    func testCustomTypeExportAndRuleConflict() throws {
        var w = Workspace(); w.accounts = [account]
        var e = Entry(statementID:UUID(),accountID:account.id,date:"2026-05-12",amount:-100,description:"PREMIUM")
        e.reviewed = true; e.customType = "Insurance"; e.payee = "Example insurer"; e.category = "保險"; w.entries = [e]
        let rows = try CSV.read(Exports.transactions(w)); XCTAssertEqual(rows[1][6],"Example insurer"); XCTAssertEqual(rows[1][7],"Insurance"); XCTAssertEqual(rows[1][8],"保險")
        var a = CategoryRule(); a.pattern = "PREMIUM"; a.customType = "One"
        var b = a; b.id = UUID(); b.customType = "Two"; w.rules = [a,b]; w.entries[0].reviewed = false
        w.applyRules(); XCTAssertNil(w.entries[0].customType); XCTAssertEqual(w.entries[0].type,.unknown)
    }

}
