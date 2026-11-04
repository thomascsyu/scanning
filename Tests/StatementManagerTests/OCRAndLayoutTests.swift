import XCTest
import AppKit
import PDFKit
@testable import StatementCore

final class OCRAndLayoutTests: XCTestCase {
    func testScannedPDFFallsBackToLocalVision() throws {
        let image = NSImage(size: NSSize(width: 1200, height: 1600))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0,y: 0,width: 1200,height: 1600).fill()
        ("HSBC SYNTHETIC STATEMENT\n02 Jan CLIENT INV-0001 100.00 CR" as NSString).draw(at: CGPoint(x: 80,y: 1300), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black]); image.unlockFocus()
        let pdf = PDFDocument(); pdf.insert(PDFPage(image: image)!, at: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf"); defer { try? FileManager.default.removeItem(at: url) }; XCTAssertTrue(pdf.write(to: url))
        let result = try PDFExtractor.read(url: url)
        XCTAssertTrue(result.lines.contains(where: \.ocr)); XCTAssertEqual(result.bank, .hsbc); XCTAssertTrue(result.text.contains("100.00")); XCTAssertFalse(result.warnings.isEmpty)
    }
    func testColumnsBalancesMultilineAndMerchantNamedTotal() {
        func line(_ text: String, x: Double, y: Double) -> TextLine { TextLine(text: text, region: SourceRegion(page: 0, rect: CGRect(x: x,y: y,width: 60,height: 12))) }
        let account = Account(name: "Test", bank: .boc, kind: .bank)
        let lines = [line("Opening balance 1,000.00",x: 10,y: 760), line("Withdrawals",x: 300,y: 700),line("Deposits",x: 400,y: 700),line("Balance",x: 500,y: 700),line("02 Jan TOTAL SOLUTIONS",x: 10,y: 650),line("100.00",x: 300,y: 650),line("900.00",x: 500,y: 650),line("Invoice INV-0002",x: 10,y: 632),line("Closing balance 900.00",x: 10,y: 550)]
        let parsed = StatementParser.parse(ExtractedPDF(lines: lines,hash: "",bank: .boc,warnings: []), statementID: UUID(),account: account,periodEnd: "2026-01-31")
        XCTAssertEqual(parsed.entries.count, 1); XCTAssertEqual(parsed.entries.first?.amount, -10000); XCTAssertEqual(parsed.entries.first?.runningBalance, 90000)
        XCTAssertEqual(parsed.openingBalance, 100000); XCTAssertEqual(parsed.closingBalance, 90000); XCTAssertTrue(parsed.entries.first?.rawDescription.contains("INV-0002") == true)
    }
}

extension OCRAndLayoutTests {
    func testDemoWorkspaceAndUnsafeBackupValues() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        var demo = try DemoWorkspace.create(documents: folder); try demo.validate()
        XCTAssertEqual(demo.reconciliationDifference(demo.statements[0]), 0)
        XCTAssertEqual(demo.outstanding(demo.invoices[0]), 200000)
        demo.entries[0].amount = Int64.max
        XCTAssertThrowsError(try demo.validate())
    }
}
