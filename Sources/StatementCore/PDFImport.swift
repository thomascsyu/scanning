import Foundation
import PDFKit
import Vision
import AppKit
import CryptoKit

public struct TextLine: Sendable {
    public var text: String
    public var region: SourceRegion
    public var ocr: Bool
    public init(text: String, region: SourceRegion, ocr: Bool = false) { self.text = text; self.region = region; self.ocr = ocr }
}
public struct ExtractedPDF: Sendable {
    public var lines: [TextLine]
    public var hash: String
    public var bank: Bank
    public var warnings: [String]
    public var text: String { lines.map(\.text).joined(separator: "\n") }
}
public enum PDFImportError: LocalizedError {
    case password, invalid
    public var errorDescription: String? { self == .password ? "This PDF needs its password." : "The PDF could not be opened." }
}
public enum PDFExtractor {
    public static func read(url: URL, password: String = "", forceOCR: Bool = false) throws -> ExtractedPDF {
        let data = try Data(contentsOf: url)
        guard let document = PDFDocument(data: data) else { throw PDFImportError.invalid }
        if document.isLocked && !document.unlock(withPassword: password) { throw PDFImportError.password }
        var lines: [TextLine] = [], warnings: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = page.string ?? ""
            let usable = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count > 30 && !text.contains("\u{FFFD}")
            if usable && !forceOCR {
                let selection = page.selection(for: page.bounds(for: .mediaBox))
                for selected in selection?.selectionsByLine() ?? [] {
                    guard let value = selected.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    lines.append(TextLine(text: value, region: SourceRegion(page: index, rect: selected.bounds(for: page))))
                }
            } else {
                lines += try recognize(page: page, index: index)
                warnings.append("Page \(index + 1) used OCR. Verify amounts and references against the original.")
            }
        }
        let text = lines.map(\.text).joined(separator: "\n").lowercased()
        let bank: Bank = text.contains("hsbc") || text.contains("香港上海滙豐") || text.contains("香港上海匯豐") ? .hsbc : text.contains("bank of china") || text.contains("中國銀行") || text.contains("中銀香港") ? .boc : .unknown
        return ExtractedPDF(lines: lines, hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bank: bank, warnings: warnings)
    }
    private static func recognize(page: PDFPage, index: Int) throws -> [TextLine] {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(300.0 / 72.0, 5000 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw LedgerError.invalid("Unable to render a PDF page for OCR.") }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale); context.translateBy(x: -bounds.minX, y: -bounds.minY); page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw PDFImportError.invalid }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hant", "en-US"]; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox
            let rect = CGRect(x: bounds.minX + b.minX * bounds.width, y: bounds.minY + b.minY * bounds.height, width: b.width * bounds.width, height: b.height * bounds.height)
            return TextLine(text: candidate.string, region: SourceRegion(page: index, rect: rect), ocr: true)
        }
    }
}
public struct ParseResult: Sendable {
    public var entries: [Entry]
    public var warnings: [String]
    public var profile: String
    public var openingBalance: Int64? = nil
    public var closingBalance: Int64? = nil
}
public enum StatementParser {
    // These profiles are intentionally unvalidated until checked against the user's real layouts.
    /// Recorded on each statement so later parser changes can identify which imports to re-extract.
    public static let version = "0.3-hsbc-layout"
    public static func parse(_ pdf: ExtractedPDF, statementID: UUID, account: Account, periodEnd: String) -> ParseResult {
        let profile = "\(pdf.bank.rawValue) · \(account.kind.rawValue) · unvalidated"
        var warnings = pdf.warnings + ["Bank layout is unvalidated. Review every row and reconcile balances before finalizing."]
        guard pdf.bank != .unknown, pdf.bank == account.bank, Day.valid(periodEnd) else {
            warnings.append("Unknown/mismatched bank or missing statement end date. Use manual entry or choose the matching account.")
            return ParseResult(entries: [], warnings: warnings, profile: "Unknown")
        }
        // PDFKit sometimes returns each table cell as a separate line. Group by baseline, then sort by x.
        var grouped: [[TextLine]] = []
        for line in pdf.lines.sorted(by: { $0.region.page == $1.region.page ? $0.region.y > $1.region.y : $0.region.page < $1.region.page }) {
            if let i = grouped.lastIndex(where: { $0[0].region.page == line.region.page && abs($0[0].region.y - line.region.y) < max(3, min($0[0].region.height, line.region.height) * 0.4) }) { grouped[i].append(line) }
            else { grouped.append([line]) }
        }
        let rows = grouped.map { group -> (String, SourceRegion, Bool, [TextLine]) in
            let sorted = group.sorted { $0.region.x < $1.region.x }
            let rect = group.dropFirst().reduce(group[0].region.rect) { $0.union($1.region.rect) }
            return (sorted.map(\.text).joined(separator: " "), SourceRegion(page: group[0].region.page, rect: rect), group.contains(where: \.ocr), sorted)
        }
        guard let moneyRegex = try? NSRegularExpression(pattern: #"(?:HK\$\s*)?\(?-?\d[\d,]*\.\d{2}(?![\d%])\)?(?:\s*(?:CR|DR))?"#, options: [.caseInsensitive]),
              let dateRegex = try? NSRegularExpression(pattern: #"^\s*(\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}(?:/\d{4})?|\d{1,2}-[A-Za-z]{3}(?:-\d{4})?|\d{1,2}\s+[A-Za-z]{3}(?:\s+\d{4})?)\b"#) else {
            warnings.append("Could not initialize the statement parser.")
            return ParseResult(entries: [], warnings: warnings, profile: profile)
        }
        let openingPhrases = ["opening balance", "previous balance", "balance brought", "b/f balance", "承前結餘", "上期結欠"]
        let closingPhrases = ["closing balance", "new balance", "balance carried", "c/f balance", "本期結欠", "期末結餘"]
        var entries: [Entry] = [], skipped = 0, inherited = 0, ignored = 0
        var debitX: Double?, creditX: Double?, balanceX: Double?
        var openingBalance: Int64?, closingBalance: Int64?
        var continuationAllowed = false
        // Some layouts (HSBC) print the date once above several transactions of the same day, even across page breaks.
        var carriedDate: (date: String, page: Int)?
        var lastDate: String?
        // A dated details line whose amount is printed on a following line.
        var pending: (text: String, region: SourceRegion, ocr: Bool)?
        func makeEntry(_ text: String, region: SourceRegion, ocr: Bool, cells: [TextLine], date: String, prefixLength: Int) -> Entry? {
            let ns = text as NSString
            let monetary = moneyRegex.matches(in: text, range: NSRange(location: prefixLength, length: ns.length - prefixLength))
            guard !monetary.isEmpty else { return nil }
            var amount: Int64?, runningBalance: Int64?
            var firstAmountColumnX: Double?
            if account.kind == .creditCard && monetary.count == 1 { amount = try? Money.parse(ns.substring(with: monetary[0].range)) }
            if account.kind == .bank, let debitX, let creditX {
                let anchors = [(debitX, -1), (creditX, 1)] + (balanceX.map { [($0, 0)] } ?? [])
                let xs = anchors.map(\.0).sorted()
                // Numbers far from every amount column (e.g. a cheque number in the details column) are not amounts.
                let tolerance = zip(xs, xs.dropFirst()).map { max(($1 - $0) * 0.75, 12) }.min() ?? .infinity
                for cell in cells {
                    guard cell.text.contains("."), let value = try? Money.parse(cell.text) else { continue }
                    let x = cell.region.x + cell.region.width / 2
                    let target = anchors.min { abs($0.0 - x) < abs($1.0 - x) }!
                    guard abs(target.0 - x) <= tolerance else { continue }
                    firstAmountColumnX = min(firstAmountColumnX ?? cell.region.x, cell.region.x)
                    if target.1 != 0 { amount = abs(value) * Int64(target.1) } else { runningBalance = value }
                }
            }
            // Explicit DR/CR is safe enough to stage, but always requires review.
            if amount == nil, account.kind == .bank, monetary.count == 1 {
                let token = ns.substring(with: monetary[0].range).uppercased()
                if token.hasSuffix("CR"), let value = try? Money.parse(token) { amount = abs(value) }
                if token.hasSuffix("DR"), let value = try? Money.parse(token) { amount = -abs(value) }
            }
            guard let amount else { return nil }
            let amountStart = max(monetary[0].range.location, prefixLength)
            let description: String
            if let firstAmountColumnX {
                // Preserve numbers/references inside details; only actual amount columns end the description.
                let detail = cells.filter { $0.region.x < firstAmountColumnX }.map(\.text).joined(separator: " ") as NSString
                let start = min(prefixLength, detail.length)
                description = detail.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                description = ns.substring(with: NSRange(location: prefixLength, length: amountStart - prefixLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var entry = Entry(statementID: statementID, accountID: account.id, date: date, amount: amount, description: description)
            entry.runningBalance = runningBalance; entry.source = region; entry.usedOCR = ocr; entry.notes = "Unvalidated parser — verify source."
            return entry
        }
        for (text, region, ocr, cells) in rows {
            let lower = text.lowercased()
            let ns = text as NSString
            let allMoney = moneyRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            let isOpening = openingPhrases.contains(where: lower.contains)
            let isClosing = closingPhrases.contains(where: lower.contains) || (lower.hasPrefix("as of") && lower.contains("balance"))
            let dateMatch = dateRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            if isOpening || isClosing {
                pending = nil
                let rowDate = dateMatch.flatMap { transactionDate(ns.substring(with: $0.range(at: 1)), end: periodEnd) }
                if let match = allMoney.last, var value = try? Money.parse(ns.substring(with: match.range)) {
                    let token = ns.substring(with: match.range).uppercased()
                    if account.kind == .bank {
                        if token.hasSuffix("CR") { value = abs(value) }
                        if token.hasSuffix("DR") { value = -abs(value) }
                    }
                    // Multi-page statements repeat B/F and C/F on every page: keep the first opening and last closing.
                    if isOpening && openingBalance == nil { openingBalance = value }
                    if isClosing { closingBalance = value }
                }
                continuationAllowed = false
                let carryOut = lower.contains("c/f balance") || lower.contains("balance carried")
                let carryIn = lower.contains("b/f balance") || lower.contains("balance brought") || lower.contains("承前結餘")
                if account.kind == .bank, carryOut, let date = rowDate ?? lastDate {
                    carriedDate = (date, region.page); lastDate = nil
                } else if account.kind == .bank, isOpening, let date = rowDate {
                    // A dated B/F row (HSBC) supplies the day for the undated transactions printed below it.
                    lastDate = date; carriedDate = nil
                } else if account.kind == .bank, carryIn,
                          let previous = entries.last, previous.source?.page == region.page - 1 {
                    lastDate = lastDate ?? (carriedDate?.page == region.page - 1 ? carriedDate?.date : nil)
                    carriedDate = nil
                } else { lastDate = nil; carriedDate = nil }
                continue
            }
            if allMoney.isEmpty, lower.contains("withdraw") || lower.contains("deposit") || lower.contains("支出") || lower.contains("存入") || lower.contains("debit") || lower.contains("credit") {
                var debit: Double?, credit: Double?, balance: Double?
                for cell in cells {
                    let label = cell.text.lowercased(), center = cell.region.x + cell.region.width / 2
                    if label == "debit" || label.contains("withdrawal") || label == "支出" || label == "提款" || label == "提取" { debit = center }
                    if label == "credit" || label.contains("deposit") || label == "存入" || label == "存款" { credit = center }
                    if label.contains("balance") || label.contains("結餘") { balance = center }
                }
                // A lone annotation such as 支出 wrapped under the details column must not move the column anchors.
                if [debit, credit, balance].compactMap({ $0 }).count >= 2 {
                    debitX = debit ?? debitX; creditX = credit ?? creditX; balanceX = balance ?? balanceX
                }
            }
            if dateMatch == nil {
                // Page furniture repeats at every page break; the running day continues past it.
                if ["statement", "page "].contains(where: lower.contains) { continuationAllowed = false; pending = nil; continue }
                if ["total", "結餘", "總額", "minimum payment", "number of transactions"].contains(where: lower.contains) { continuationAllowed = false; lastDate = nil; carriedDate = nil; pending = nil; continue }
            }
            guard let dm = dateMatch else {
                // Only positioned bank columns classify an undated row reliably; card lines such as FX notes stay excluded.
                let columnTable = lastDate != nil && account.kind == .bank && debitX != nil && creditX != nil
                let pendingAbove = pending.flatMap { p in p.region.page == region.page && p.region.y - region.y > 0 && p.region.y - region.y < 28 ? p : nil }
                if !allMoney.isEmpty, columnTable, let date = lastDate, var entry = makeEntry(text, region: region, ocr: ocr, cells: cells, date: date, prefixLength: 0) {
                    if let p = pendingAbove {
                        entry.rawDescription = (p.text + " " + entry.rawDescription).trimmingCharacters(in: .whitespaces)
                        entry.source = SourceRegion(page: region.page, rect: p.region.rect.union(region.rect)); entry.usedOCR = entry.usedOCR || p.ocr
                    } else { inherited += 1 }
                    pending = nil
                    entries.append(entry); continuationAllowed = true
                } else if allMoney.isEmpty, let p = pendingAbove, text.count > 2 {
                    pending = (p.text + " " + text, SourceRegion(page: region.page, rect: p.region.rect.union(region.rect)), p.ocr || ocr)
                } else if allMoney.isEmpty || columnTable, continuationAllowed, let last = entries.indices.last, entries[last].source?.page == region.page,
                          let prev = entries[last].source, prev.y - region.y > 0, prev.y - region.y < 28, text.count > 2 {
                    // In a column table, a figure outside the amount columns (e.g. "REM USD5500.00") is detail text.
                    entries[last].rawDescription += " " + text
                    entries[last].source = SourceRegion(page: region.page, rect: prev.rect.union(region.rect))
                    entries[last].usedOCR = entries[last].usedOCR || ocr
                } else if !allMoney.isEmpty, !entries.isEmpty || lastDate != nil {
                    // Inside the transaction area, a line with an amount that cannot be placed must be surfaced, not dropped.
                    ignored += 1
                }
                continue
            }
            continuationAllowed = false; pending = nil
            guard let date = transactionDate(ns.substring(with: dm.range(at: 1)), end: periodEnd) else { lastDate = nil; skipped += 1; continue }
            guard moneyRegex.firstMatch(in: text, range: NSRange(location: dm.range.length, length: ns.length - dm.range.length)) != nil else {
                // A bare date (e.g. the statement-date box atop each page) is not a transaction. A dated details line
                // without an amount starts a new day whose amount follows on the next line.
                let details = ns.substring(from: dm.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
                if account.kind == .bank, !details.isEmpty { lastDate = date; carriedDate = nil; pending = (details, region, ocr) }
                continue
            }
            lastDate = date; carriedDate = nil
            guard let entry = makeEntry(text, region: region, ocr: ocr, cells: cells, date: date, prefixLength: dm.range.length) else { skipped += 1; continue }
            entries.append(entry); continuationAllowed = true
        }
        for i in entries.indices { entries[i].extractReferences() }
        if inherited > 0 { warnings.append("\(inherited) rows had no date of their own and use the date printed above them. Verify those dates.") }
        if ignored > 0 { warnings.append("\(ignored) undated lines with amounts could not be matched to a transaction and were ignored. Compare the PDF and add missing transactions manually.") }
        if skipped > 0 { warnings.append("\(skipped) dated rows could not be parsed safely. Compare the PDF and add missing transactions manually.") }
        if entries.isEmpty { warnings.append("No reliable transaction rows found. Enter rows manually; this layout needs a sample-based parsing profile.") }
        return ParseResult(entries: entries, warnings: warnings, profile: profile, openingBalance: openingBalance, closingBalance: closingBalance)
    }
    public static func transactionDate(_ text: String, end: String) -> String? {
        if let date = try? Day.parse(text) { return date }
        guard let year = Int(end.prefix(4)) else { return nil }
        let separator = text.contains("/") ? "/" : text.contains("-") ? "-" : " "
        guard let date = try? Day.parse(text + separator + String(year)) else { return nil }
        if date > end { return try? Day.parse(text + separator + String(year - 1)) }
        return date
    }
}
