import XCTest
@testable import StatementCore

/// Synthetic rows laid out like an HSBC business card statement (post date, transaction date, details, HKD amount).
final class HSBCCardTests: XCTestCase {
    let account = Account(name: "HSBC card", bank: .hsbc, kind: .creditCard)
    func row(_ text: String, _ y: Double, page: Int = 0) -> TextLine {
        TextLine(text: text, region: SourceRegion(page: page, rect: CGRect(x: 90, y: y, width: 500, height: 9)))
    }
    func parse(_ lines: [TextLine]) -> ParseResult {
        StatementParser.parse(ExtractedPDF(lines: lines, hash: "synthetic", bank: .hsbc, warnings: []), statementID: UUID(), account: account, periodEnd: "2025-03-28")
    }
    var statement: [TextLine] {
        [
            row("STATEMENT OF BUSINESS CARD ACCOUNT", 780),
            row("Statement date 結單日 Statement balance 結單結欠餘額", 700),
            row("28 MAR 2025 HKD14,717.14", 690),
            row("PREVIOUS BALANCE 49,773.89", 600),
            row("03MAR 02MAR IFS PAYMENT - THANK YOU 49,773.89CR", 588),
            row("06MAR 06MAR FINANCE CHARGE REV 734.52CR", 576),
            row("JUN2024 FC REFD", 564),
            row("5592 4033 3870 1617 YU CHAK SHING GABRIEL CONSUL LTD", 540),
            row("03MAR 01MAR GOOGLE*GSUITE GABRIELC CC GOOGLE.COM SG 169.20", 528),
            row("03MAR 28FEB BIRDIE MOBILE LIMITED KWUN TONG HK 50.00", 516),
            row("03MAR 02MAR Google GSUITE_gabriel. Dublin IE GBP 12.00 120.24", 504),
            row("*EXCHANGE RATE: 10.02000", 492),
            row("04MAR 03MAR APOLLO.IO COVINA US USD 59.00 467.97", 480),
            row("Current minimum payment due 148.00", 300),
            row("28 MAR 2025 HKD14,717.14 Amount enclosed", 200),
        ]
    }
    func testHSBCCardRowsAreExtracted() {
        let r = parse(statement)
        XCTAssertEqual(r.entries.count, 6)
        XCTAssertEqual(r.entries.map(\.date), ["2025-03-02", "2025-03-06", "2025-03-01", "2025-02-28", "2025-03-02", "2025-03-03"])
        // Charges are positive; payments and credits reduce the amount owed. The HKD column wins over foreign amounts.
        XCTAssertEqual(r.entries.map(\.amount), [-4_977_389, -73_452, 16_920, 5_000, 12_024, 46_797])
        XCTAssertEqual(r.openingBalance, 4_977_389)
        XCTAssertTrue(r.entries[1].rawDescription.contains("JUN2024 FC REFD"))
        XCTAssertFalse(r.entries[1].rawDescription.contains("5592"))
        XCTAssertTrue(r.entries[4].rawDescription.hasPrefix("Google GSUITE_gabriel. Dublin IE GBP 12.00"))
        XCTAssertFalse(r.entries.contains { $0.rawDescription.hasPrefix("HKD") })
    }
    func testCompactDayMonthParses() {
        XCTAssertEqual(StatementParser.transactionDate("03MAR", end: "2025-03-28"), "2025-03-03")
        XCTAssertEqual(StatementParser.transactionDate("28 MAR 2025", end: "2025-03-28"), "2025-03-28")
        XCTAssertEqual(StatementParser.transactionDate("30DEC", end: "2025-01-28"), "2024-12-30")
    }
    func testEachRowRecordsItsCardNumber() throws {
        let second = [
            row("4512 0000 1111 2222 CHAN TAI MAN", 470),
            row("05MAR 05MAR UBER *TRIP HONG KONG HK 88.00", 458),
        ]
        let r = parse(statement.filter { $0.region.y >= 480 } + second + statement.filter { $0.region.y < 480 })
        XCTAssertEqual(r.entries.map(\.cardNumber), [nil, nil, "1617", "1617", "1617", "1617", "2222"])
        // Only the last four digits are kept.
        XCTAssertFalse(r.entries.contains { ($0.cardNumber ?? "").count != 4 && $0.cardNumber != nil })
        let statementID = UUID()
        var w = Workspace(); w.accounts = [account]
        w.statements = [Statement(accountID: account.id, filename: "card.pdf", storedFilename: "card.pdf", hash: "h")]
        w.statements[0].id = statementID
        w.entries = r.entries.map { var e = $0; e.statementID = statementID; return e }
        XCTAssertEqual(w.cardNumbers(forAccount: account.id), ["1617", "2222"])
        XCTAssertEqual(w.cardNumbers(inStatement: statementID), ["1617", "2222"])
        XCTAssertEqual(w.statements(forAccount: account.id, card: "2222").map(\.id), [statementID])
        XCTAssertTrue(w.statements(forAccount: account.id, card: "9999").isEmpty)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exports.allTransactions(w, accountID: account.id, card: "2222").write(to: url)
        let rows = try InvoiceReader.sheets(url: url)[0].rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][14], "Card")
        XCTAssertEqual(rows[1][14], "•••• 2222")
    }
}
