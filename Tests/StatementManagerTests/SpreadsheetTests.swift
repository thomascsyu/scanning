import XCTest
import CoreXLSX
import ZIPFoundation
@testable import StatementCore

final class SpreadsheetTests: XCTestCase {
    func workbook(uses1904: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        let archive = try Archive(url: url, accessMode: .create)
        let parts = [
            "[Content_Types].xml": """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/></Types>
            """,
            "_rels/.rels": """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """,
            "xl/workbook.xml": """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><workbookPr date1904="\(uses1904 ? "1" : "0")"/><sheets><sheet name="Invoices" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """,
            "xl/styles.xml": """
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="000000"/></numFmts><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0"/></cellXfs></styleSheet>
            """,
            "xl/worksheets/sheet1.xml": """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Invoice number</t></is></c><c r="B1" t="inlineStr"><is><t>Client</t></is></c><c r="C1" t="inlineStr"><is><t>Invoice date</t></is></c><c r="D1" t="inlineStr"><is><t>Original total</t></is></c><c r="E1" t="inlineStr"><is><t>Starting outstanding</t></is></c></row><row r="2"><c r="A2" s="1"><v>123</v></c><c r="B2" t="inlineStr"><is><t>測試客戶</t></is></c><c r="C2"><v>\(uses1904 ? "44561" : "46023")</v></c><c r="D2"><v>1200.50</v></c><c r="E2"><v>200.50</v></c></row></sheetData></worksheet>
            """
        ]
        for (path, text) in parts {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
        }
        return url
    }
    func testXLSXDateSystemsAndZeroPaddedIdentifiers() throws {
        for uses1904 in [false, true] {
            let url = try workbook(uses1904: uses1904); defer { try? FileManager.default.removeItem(at: url) }
            let sheets = try InvoiceReader.sheets(url: url)
            XCTAssertEqual(sheets.count, 1)
            let invoices = try InvoiceReader.invoices(sheet: sheets[0], mapping: InvoiceReader.suggestedMapping(headers: sheets[0].rows[0]))
            XCTAssertEqual(invoices[0].number, "000123"); XCTAssertEqual(invoices[0].client, "測試客戶"); XCTAssertEqual(invoices[0].date, "2026-01-01"); XCTAssertEqual(invoices[0].startingOutstanding, 20050)
        }
    }
    func testStatementExportRoundTrip() throws {
        let account = Account(name: "HSBC operating", bank: .hsbc, kind: .bank)
        var statement = Statement(accountID: account.id, filename: "Synthetic.pdf", storedFilename: "synthetic.pdf", hash: "hash")
        statement.periodEnd = "2026-01-31"
        var entry = Entry(statementID: statement.id, accountID: account.id, date: "2026-01-20", amount: -12345, description: " =HYPERLINK(\"x\")")
        entry.payee = "測試客戶"; entry.reviewed = false; entry.source = SourceRegion(page: 0, rect: .zero)
        var workspace = Workspace(); workspace.accounts = [account]; workspace.statements = [statement]; workspace.entries = [entry]
        let data = try Exports.statement(workspace, statementID: statement.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let sheets = try InvoiceReader.sheets(url: url)
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].name, "Transactions")
        let row = sheets[0].rows[1]
        XCTAssertEqual(row[5], " =HYPERLINK(\"x\")")
        XCTAssertEqual(row[6], "測試客戶")
        XCTAssertEqual(row[3], "-123.45")
        XCTAssertEqual(row[14], "No")
        guard let file = XLSXFile(filepath: url.path) else { return XCTFail("Missing workbook") }
        let worksheet = try file.parseWorksheet(at: "xl/worksheets/sheet1.xml")
        let amountCell = worksheet.data?.rows[1].cells.first { $0.reference.column.value == "D" }
        XCTAssertNil(amountCell?.inlineString)
        XCTAssertEqual(amountCell?.value, "-123.45")
        let archive = try Archive(url: url, accessMode: .read)
        var sheetXML = Data()
        guard let sheetEntry = archive["xl/worksheets/sheet1.xml"] else { return XCTFail("Missing worksheet") }
        _ = try archive.extract(sheetEntry) { sheetXML.append($0) }
        let xml = String(decoding: sheetXML, as: UTF8.self)
        XCTAssertTrue(xml.contains("<v>-123.45</v>"))
        XCTAssertTrue(archive["xl/styles.xml"] != nil)
    }
    func testAllTransactionsExcelIncludesEveryStatementRow() throws {
        let operating = Account(name: "HSBC operating", bank: .hsbc, kind: .bank)
        let card = Account(name: "HSBC card", bank: .hsbc, kind: .creditCard)
        var january = Statement(accountID: operating.id, filename: "January.pdf", storedFilename: "a.pdf", hash: "a")
        january.periodEnd = "2026-01-31"
        var february = Statement(accountID: card.id, filename: "February.pdf", storedFilename: "b.pdf", hash: "b")
        february.periodEnd = "2026-02-28"
        var reviewed = Entry(statementID: january.id, accountID: operating.id, date: "2026-01-05", amount: 1000, description: "Client receipt")
        reviewed.reviewed = true
        reviewed.payee = "測試客戶"
        var unreviewed = Entry(statementID: january.id, accountID: operating.id, date: "2026-01-20", amount: -1000, description: " =HYPERLINK(\"x\")")
        var cardCharge = Entry(statementID: february.id, accountID: card.id, date: "2026-02-02", amount: 250, description: "Software")
        cardCharge.source = SourceRegion(page: 1, rect: .zero)
        var workspace = Workspace()
        workspace.accounts = [operating, card]
        workspace.statements = [january, february]
        workspace.entries = [unreviewed, cardCharge, reviewed]
        XCTAssertEqual(workspace.statements(in: .bank).map(\.filename), ["January.pdf"])
        XCTAssertEqual(workspace.statements(in: .creditCard).map(\.filename), ["February.pdf"])
        XCTAssertEqual(Exports.suggestedAllTransactionsFilename(on: "2026-01-31"), "all-transactions-2026-01-31.xlsx")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exports.allTransactions(workspace, folder: .bank).write(to: url)
        let rows = try InvoiceReader.sheets(url: url)[0].rows
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].last, "Statement date")
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0[0] == "HSBC operating" })
        XCTAssertEqual(rows[1][3], "10.00")
        XCTAssertEqual(rows[1][6], "測試客戶")
        XCTAssertEqual(rows[1][14], "Yes")
        XCTAssertEqual(rows[1][15], "2026-01-31")
        XCTAssertEqual(rows[2][3], "-10.00")
        XCTAssertEqual(rows[2][5], " =HYPERLINK(\"x\")")
        XCTAssertEqual(rows[2][14], "No")
        let cardURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: cardURL) }
        try Exports.allTransactions(workspace, folder: .creditCard).write(to: cardURL)
        let cardRows = try InvoiceReader.sheets(url: cardURL)[0].rows
        XCTAssertEqual(cardRows.count, 2)
        XCTAssertEqual(cardRows[1][0], "HSBC card")
        XCTAssertEqual(cardRows[1][3], "2.50")
        XCTAssertEqual(cardRows[1][4], "Positive increases amount owed")
        XCTAssertEqual(cardRows[1][12], "February.pdf")
        XCTAssertEqual(cardRows[1][13], "2")
        XCTAssertEqual(cardRows[1][15], "2026-02-28")
        let statementURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: statementURL) }
        try Exports.statement(workspace, statementID: january.id).write(to: statementURL)
        let statementRows = try InvoiceReader.sheets(url: statementURL)[0].rows
        XCTAssertEqual(statementRows.count, 3)
        XCTAssertEqual(statementRows[0].count, 15)
        XCTAssertTrue(statementRows.dropFirst().allSatisfy { $0[12] == "January.pdf" })
        XCTAssertEqual(statementRows.filter { $0.count > 14 && $0[14] == "No" }.count, 1)
        let archive = try Archive(url: url, accessMode: .read)
        var sheetXML = Data()
        guard let sheetEntry = archive["xl/worksheets/sheet1.xml"] else { return XCTFail("Missing worksheet") }
        _ = try archive.extract(sheetEntry) { sheetXML.append($0) }
        let xml = String(decoding: sheetXML, as: UTF8.self)
        XCTAssertTrue(xml.contains("<v>10.00</v>"))
        XCTAssertFalse(xml.contains("February.pdf"))
        XCTAssertTrue(xml.contains("s=\"1\""))
        XCTAssertTrue(xml.contains("ySplit=\"1\""))
        var styles = Data()
        guard let stylesEntry = archive["xl/styles.xml"] else { return XCTFail("Missing styles") }
        _ = try archive.extract(stylesEntry) { styles.append($0) }
        XCTAssertTrue(String(decoding: styles, as: UTF8.self).contains("formatCode=\"0.00\""))
        let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        try Exports.allTransactions(Workspace(), folder: .creditCard).write(to: emptyURL)
        XCTAssertEqual(try InvoiceReader.sheets(url: emptyURL)[0].rows.count, 1)
    }
}
