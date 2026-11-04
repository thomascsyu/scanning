import Foundation

public extension ExtractedPDF {
    var suggestedPeriodEnd: String? {
        let pattern = #"(?:statement\s+date|結單日期)\s*[:：]?\s*(\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}|\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return try? Day.parse((text as NSString).substring(with: match.range(at: 1)))
    }
    var declaredTransactionCount: Int? {
        func count(_ label: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: label) + #"\s+(\d+)\s+HKD\b"#, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return Int((text as NSString).substring(with: match.range(at: 1)))
        }
        guard let deposits = count("Deposits"), let withdrawals = count("Withdrawals"), deposits <= 50_000, withdrawals <= 50_000 else { return nil }
        return deposits + withdrawals
    }
}
public extension Workspace {
    /// Repair only an empty prior import, with independently matching printed count AND balance.
    /// Existing reviewed rows, edits, allocations and other statements are never replaced, and a statement the
    /// user deliberately saved for manual entry is left alone.
    mutating func recoverEmptyImport(statementID: UUID, pdf: ExtractedPDF) throws -> Bool {
        guard let index = statements.firstIndex(where: { $0.id == statementID }),
              statements[index].manualEntry != true,
              !entries.contains(where: { $0.statementID == statementID }),
              pdf.hash == statements[index].hash,
              let account = account(statements[index].accountID),
              let expectedCount = pdf.declaredTransactionCount, expectedCount > 0 else { return false }
        let date = pdf.suggestedPeriodEnd ?? statements[index].periodEnd
        let result = StatementParser.parse(pdf, statementID: statementID, account: account, periodEnd: date)
        guard result.entries.count == expectedCount, let opening = result.openingBalance, let closing = result.closingBalance,
              opening + result.entries.reduce(0, { $0 + $1.amount }) == closing else { return false }
        var next = self
        next.entries.append(contentsOf: result.entries)
        next.statements[index].periodEnd = date
        next.statements[index].openingBalance = opening; next.statements[index].closingBalance = closing
        next.statements[index].profile = result.profile; next.statements[index].parserVersion = StatementParser.version
        next.statements[index].warnings = result.warnings + ["Recovered a previously empty import. Transaction count and totals match the PDF; each row still needs your review."]
        next.statements[index].reconciled = false
        next.flagDuplicates(); next.applyRules(); try next.validate(); self = next
        return true
    }
}
