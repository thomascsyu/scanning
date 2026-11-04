import Foundation
import AppKit
import PDFKit
import CryptoKit

public enum DemoWorkspace {
    /// Synthetic data only. Kept in a separate store when launched with --demo.
    public static func create(documents: URL) throws -> Workspace {
        var w = Workspace(); w.businessName = "Demo business · synthetic data"
        let account = Account(name: "HSBC operating · demo", bank: .hsbc, kind: .bank)
        w.accounts = [account, Account(name: "BOC card · demo", bank: .boc, kind: .creditCard)]
        let data = NSMutableData(); var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw PDFImportError.invalid }
        context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("HSBC · SYNTHETIC DEMONSTRATION ONLY" as NSString).draw(at: CGPoint(x: 36,y: 770), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 17)])
        ("January 2026 · HKD · Not a real bank statement" as NSString).draw(at: CGPoint(x: 36,y: 740), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        let lines = ["Opening balance                              10,000.00", "05 Jan   Client payment INV-001             8,000.00 CR", "08 Jan   EXAMPLE SOFTWARE                     240.00 DR", "12 Jan   Cheque deposit 000123              2,500.00 CR", "18 Jan   EXAMPLE OFFICE SUPPLY                680.00 DR", "25 Jan   Bank service fee                     50.00 DR", "Closing balance                              19,530.00"]
        for (i, line) in lines.enumerated() { (line as NSString).draw(at: CGPoint(x: 36,y: 690 - i * 36), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]) }
        NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
        let filename = UUID().uuidString + ".pdf"; try (data as Data).write(to: documents.appendingPathComponent(filename))
        let hash = SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
        var statement = Statement(accountID: account.id, filename: "Demo HSBC January.pdf", storedFilename: filename, hash: hash)
        statement.periodStart = "2026-01-01"; statement.periodEnd = "2026-01-31"; statement.openingBalance = 1_000_000; statement.closingBalance = 1_953_000; statement.profile = "Synthetic demonstration"; statement.warnings = ["Synthetic data only. Real bank parsing profiles remain unvalidated."]
        w.statements = [statement]
        let amounts: [Int64] = [800000, -24000, 250000, -68000, -5000]
        let days = ["05", "08", "12", "18", "25"]
        let descriptions = ["Client payment INV-001", "EXAMPLE SOFTWARE", "Cheque deposit 000123", "EXAMPLE OFFICE SUPPLY", "Bank service fee"]
        for i in 0..<5 {
            var entry = Entry(statementID: statement.id, accountID: account.id, date: "2026-01-" + days[i], amount: amounts[i], description: descriptions[i]); entry.source = SourceRegion(page: 0, rect: CGRect(x: 36,y: 654 - i * 36,width: 500,height: 16)); entry.reviewed = i != 2
            entry.type = [.clientPayment, .purchase, .chequeDeposit, .purchase, .fee][i]; entry.category = ["Client receipts", "Software", "Uncategorized", "Office supplies", "Bank fees"][i]
            if i == 0 { entry.invoiceReference = "INV-001"; entry.payee = "Example Client" }
            if i == 2 { entry.chequeReference = "000123" }
            w.entries.append(entry)
        }
        var invoice = Invoice(number: "INV-001", client: "Example Client", date: "2026-01-01", total: 1_000_000, outstanding: 1_000_000); invoice.dueDate = "2026-02-01"; w.invoices = [invoice]
        try w.allocate(entryID: w.entries[0].id, invoiceID: invoice.id, amount: 800000)
        w.audit = [AuditRecord("Created synthetic demonstration workspace")]; return w
    }
}
