import XCTest
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
}
