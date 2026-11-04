import Foundation
import CoreXLSX
import ZIPFoundation

public enum CSV {
    public static func read(_ text: String) throws -> [[String]] {
        let chars = Array(text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, closed = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" { cell.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { cell.append(c) }
            } else if c == "\"" {
                guard cell.isEmpty && !closed else { throw LedgerError.invalid("Malformed CSV quote.") }; quoted = true
            } else if c == "," { row.append(cell); cell = ""; closed = false }
            else if c == "\n" || c == "\r" {
                row.append(cell); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = []; cell = ""; closed = false
                if c == "\r" && i + 1 < chars.count && chars[i+1] == "\n" { i += 1 }
            } else {
                if closed && c != " " && c != "\t" { throw LedgerError.invalid("Unexpected text after a quoted CSV value.") }
                if !closed { cell.append(c) }
            }
            i += 1
        }
        guard !quoted else { throw LedgerError.invalid("CSV contains an unclosed quoted field.") }
        row.append(cell); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; return rows
    }
    public static func write(_ rows: [[String]], numericColumns: Set<Int> = []) -> String {
        rows.enumerated().map { ri, row in row.enumerated().map { ci, original in
            var value = original
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let trustedNumber = ri > 0 && numericColumns.contains(ci) && value.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil
            if !trustedNumber && (trimmed.first.map { "=+-@".contains($0) } == true || value.hasPrefix("\t") || value.hasPrefix("\r")) { value = "'" + value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
public struct Sheet: Sendable {
    public var name: String
    public var rows: [[String]]
    public var uses1904Dates: Bool
    public init(name: String, rows: [[String]], uses1904Dates: Bool = false) { self.name = name; self.rows = rows; self.uses1904Dates = uses1904Dates }
}
public enum InvoiceColumn: String, CaseIterable, Identifiable, Sendable {
    case number = "Invoice number", client = "Client", date = "Invoice date", total = "Original total", outstanding = "Starting outstanding", dueDate = "Due date", currency = "Currency"
    public var id: String { rawValue }
    public var required: Bool { ![Self.dueDate, .currency].contains(self) }
}
public enum InvoiceReader {
    public static func sheets(url: URL) throws -> [Sheet] {
        if url.pathExtension.lowercased() == "csv" {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw LedgerError.invalid("Save the CSV as UTF-8 to preserve Chinese text.") }
            return [Sheet(name: url.lastPathComponent, rows: try CSV.read(text))]
        }
        guard url.pathExtension.lowercased() == "xlsx", let file = XLSXFile(filepath: url.path) else { throw LedgerError.invalid("Use an unencrypted .xlsx or UTF-8 CSV file.") }
        let shared = try file.parseSharedStrings()
        let styles = try? file.parseStyles()
        let archive = try Archive(url: url, accessMode: .read)
        let metadata = WorkbookMetadata()
        if let entry = archive["xl/workbook.xml"] {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let parser = XMLParser(data: data); parser.delegate = metadata
            guard parser.parse() else { throw LedgerError.invalid("Unable to read workbook date settings.") }
        }
        var result: [Sheet] = []
        for workbook in try file.parseWorkbooks() {
            for (name, path) in try file.parseWorksheetPathsAndNames(workbook: workbook) {
                let sheet = try file.parseWorksheet(at: path)
                var rows: [[String]] = []
                for row in sheet.data?.rows ?? [] {
                    var values: [String] = []
                    for cell in row.cells {
                        let letters = cell.reference.column.value
                        let column = letters.utf8.reduce(0) { $0 * 26 + Int($1) - 64 } - 1
                        guard column >= 0 && column < 512 else { throw LedgerError.invalid("Invoice worksheets may contain at most 512 columns.") }
                        while values.count <= column { values.append("") }
                        if let shared, let value = cell.stringValue(shared) { values[column] = value }
                        else { values[column] = cell.inlineString?.text ?? cell.value ?? "" }
                        if let styles, let formatID = cell.format(in: styles)?.numberFormatId,
                           let code = styles.numberFormats?.items.first(where: { $0.id == formatID })?.formatCode,
                           code.range(of: #"^0{2,20}$"#, options: .regularExpression) != nil,
                           let raw = cell.value, raw.allSatisfy({ $0.isNumber }), raw.count < code.count {
                            values[column] = String(repeating: "0", count: code.count - raw.count) + raw
                        }
                    }
                    if values.contains(where: { !$0.isEmpty }) { rows.append(values) }
                }
                result.append(Sheet(name: name ?? "Worksheet", rows: rows, uses1904Dates: metadata.uses1904))
            }
        }
        return result
    }
    public static func suggestedMapping(headers: [String]) -> [String: Int] {
        let aliases: [InvoiceColumn: [String]] = [.number: ["invoice number", "invoice", "invoice no", "發票號碼", "發票編號"], .client: ["client", "customer", "客戶"], .date: ["invoice date", "date", "日期"], .total: ["original total", "total", "amount", "總額"], .outstanding: ["starting outstanding", "outstanding", "balance", "未付金額"], .dueDate: ["due date", "到期日"], .currency: ["currency", "幣種"]]
        var map: [String: Int] = [:]
        for column in InvoiceColumn.allCases {
            if let i = headers.firstIndex(where: { header in (aliases[column] ?? []).contains(header.trimmingCharacters(in: .whitespaces).lowercased()) }) { map[column.rawValue] = i }
        }
        return map
    }
    public static func invoices(sheet: Sheet, mapping: [String: Int]) throws -> [Invoice] {
        for column in InvoiceColumn.allCases where column.required {
            guard let i = mapping[column.rawValue], i >= 0, i < (sheet.rows.first?.count ?? 0) else { throw LedgerError.invalid("Map the \(column.rawValue) column.") }
        }
        let required = InvoiceColumn.allCases.filter(\.required).compactMap { mapping[$0.rawValue] }
        guard Set(required).count == required.count else { throw LedgerError.invalid("Map each required field to a different column.") }
        var invoices: [Invoice] = []
        for (offset, row) in sheet.rows.dropFirst().enumerated() {
            func value(_ column: InvoiceColumn) -> String { guard let i = mapping[column.rawValue], i >= 0, i < row.count else { return "" }; return row[i].trimmingCharacters(in: .whitespacesAndNewlines) }
            func date(_ text: String) throws -> String {
                if let serial = Double(text), serial >= 1 && serial < 100000 {
                    // Excel's 1900 date system (including its historical leap-year offset).
                    let d = Date(timeIntervalSince1970: (serial - (sheet.uses1904Dates ? 24107 : 25569)).rounded(.down) * 86400)
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
                }
                return try Day.parse(text)
            }
            do {
                let currency = value(.currency).uppercased()
                guard currency.isEmpty || ["HKD", "HK$", "港幣", "港元"].contains(currency) else { throw LedgerError.invalid("Only HKD invoices are supported.") }
                var invoice = Invoice(number: value(.number), client: value(.client), date: try date(value(.date)), total: try Money.parse(value(.total)), outstanding: try Money.parse(value(.outstanding)))
                if !value(.dueDate).isEmpty { invoice.dueDate = try date(value(.dueDate)) }
                invoices.append(invoice)
            } catch { throw LedgerError.invalid("Row \(offset + 2): \(error.localizedDescription)") }
        }
        guard !invoices.isEmpty else { throw LedgerError.invalid("The worksheet has no invoice rows.") }
        var test = Workspace(); try test.importInvoices(invoices, filename: "Validation"); return invoices
    }
}
public enum XLSX {
    /// `decimalColumns` are money amounts (`0.00`). `integerColumns` are whole numbers such as a PDF page.
    public static func write(_ rows: [[String]], sheetName: String = "Transactions", decimalColumns: Set<Int> = [], integerColumns: Set<Int> = []) throws -> Data {
        guard !rows.isEmpty else { throw LedgerError.invalid("Cannot write an empty workbook.") }
        let safeName = String(sheetName.prefix(31))
        let width = max(rows.map(\.count).max() ?? 1, 1)
        let span = "A1:\(columnLetter(width - 1))\(rows.count)"
        var sheetRows = ""
        for (ri, row) in rows.enumerated() {
            var cells = ""
            for (ci, value) in row.enumerated() {
                let ref = columnLetter(ci) + String(ri + 1)
                let decimal = ri > 0 && decimalColumns.contains(ci) && value.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil
                let integer = ri > 0 && integerColumns.contains(ci) && value.range(of: #"^\d+$"#, options: .regularExpression) != nil
                if decimal {
                    cells += "<c r=\"\(ref)\" s=\"1\"><v>\(value)</v></c>"
                } else if integer {
                    cells += "<c r=\"\(ref)\" s=\"2\"><v>\(value)</v></c>"
                } else {
                    cells += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(xmlEscape(value))</t></is></c>"
                }
            }
            sheetRows += "<row r=\"\(ri + 1)\">\(cells)</row>"
        }
        let worksheet = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="\(span)"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetData>\(sheetRows)</sheetData></worksheet>
        """
        let parts: [String: String] = [
            "[Content_Types].xml": """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
            """,
            "_rels/.rels": """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """,
            "xl/workbook.xml": """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(xmlEscapeAttribute(safeName))" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """,
            "xl/styles.xml": """
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="0.00"/></numFmts><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs></styleSheet>
            """,
            "xl/worksheets/sheet1.xml": worksheet
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let archive = try Archive(url: url, accessMode: .create)
            for (path, text) in parts {
                let data = Data(text.utf8)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) })
            }
        }
        return try Data(contentsOf: url)
    }

    private static func columnLetter(_ index: Int) -> String {
        var n = index + 1, letters = ""
        while n > 0 {
            n -= 1
            letters = String(UnicodeScalar(65 + (n % 26))!) + letters
            n /= 26
        }
        return letters
    }

    private static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func xmlEscapeAttribute(_ text: String) -> String { xmlEscape(text) }
}

public enum Exports {
    private static let transactionHeader = ["Account", "Date", "Currency", "Amount", "Amount convention", "Original description", "Payee / client", "Type", "Category", "Invoice reference", "Cheque reference", "Bank reference", "Source", "Page"]
    private static func entryRow(_ w: Workspace, _ e: Entry) -> [String] {
        let account = w.account(e.accountID)
        return [account?.name ?? "", e.date, "HKD", Money.plain(e.amount), account?.kind == .creditCard ? "Positive increases amount owed" : "Positive is money received", e.rawDescription, e.payee, e.typeTitle, e.category, e.invoiceReference, e.chequeReference, e.bankReference, w.statements.first { $0.id == e.statementID }?.filename ?? "", e.source.map { String($0.page + 1) } ?? ""]
    }
    public static func transactions(_ w: Workspace) -> String {
        let rows = w.entries.filter(\.reviewed).sorted { $0.date < $1.date }.map { entryRow(w, $0) }
        return CSV.write([transactionHeader] + rows, numericColumns: [3, 13])
    }
    private static func workbookRows(_ w: Workspace, entries: [Entry], includeStatementDate: Bool) -> [[String]] {
        var header = transactionHeader + ["Reviewed"]
        if includeStatementDate { header.append("Statement date") }
        let body = entries.map { entry -> [String] in
            var row = entryRow(w, entry) + [entry.reviewed ? "Yes" : "No"]
            if includeStatementDate { row.append(w.statements.first { $0.id == entry.statementID }?.periodEnd ?? "") }
            return row
        }
        return [header] + body
    }
    public static func statement(_ w: Workspace, statementID: UUID) throws -> Data {
        guard w.statements.contains(where: { $0.id == statementID }) else { throw LedgerError.invalid("Statement not found.") }
        let entries = w.entries.filter { $0.statementID == statementID }.sorted { $0.date < $1.date }
        return try XLSX.write(workbookRows(w, entries: entries, includeStatementDate: false), decimalColumns: [3], integerColumns: [13])
    }
    /// Every transaction on every statement, reviewed or not, in transaction-date order.
    public static func allTransactions(_ w: Workspace) throws -> Data {
        let entries = w.entries.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            let leftName = w.statements.first { $0.id == lhs.statementID }?.filename ?? ""
            let rightName = w.statements.first { $0.id == rhs.statementID }?.filename ?? ""
            if leftName != rightName { return leftName < rightName }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return try XLSX.write(workbookRows(w, entries: entries, includeStatementDate: true), decimalColumns: [3], integerColumns: [13])
    }
    public static func suggestedStatementFilename(_ statement: Statement) -> String {
        let base = (statement.filename as NSString).deletingPathExtension
        let suffix = statement.periodEnd.isEmpty ? Day.today : statement.periodEnd
        return "\(base)-\(suffix).xlsx"
    }
    public static func suggestedAllTransactionsFilename(on day: String = Day.today) -> String {
        "all-transactions-\(day).xlsx"
    }
    public static func invoices(_ w: Workspace) -> String {
        CSV.write([["Invoice number", "Client", "Invoice date", "Due date", "Currency", "Original total", "Starting outstanding", "Current outstanding", "Status"]] + w.invoices.map { [$0.number, $0.client, $0.date, $0.dueDate, "HKD", Money.plain($0.total), Money.plain($0.startingOutstanding), Money.plain(w.outstanding($0)), w.invoiceStatus($0)] }, numericColumns: [5,6,7])
    }
    public static func allocations(_ w: Workspace) -> String {
        CSV.write([["Allocation ID", "Payment ID", "Invoice number", "Currency", "Amount"]] + w.allocations.map { allocation in [allocation.id.uuidString, allocation.entryID.uuidString, w.invoices.first { $0.id == allocation.invoiceID }?.number ?? "", "HKD", Money.plain(allocation.amount)] }, numericColumns: [4])
    }
}

private final class WorkbookMetadata: NSObject, XMLParserDelegate {
    var uses1904 = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "workbookPr" { uses1904 = ["1", "true"].contains(attributes["date1904"] ?? "") }
    }
}
