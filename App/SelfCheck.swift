import Foundation
import StatementCore

@MainActor func runSelfCheck() throws {
    let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("SelfCheck-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let originals = root.appendingPathComponent("Originals")
    try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
    let workspace = try DemoWorkspace.create(documents: originals)
    let repository = try LedgerRepository(url: root.appendingPathComponent("check.store"))
    try repository.save(workspace)
    guard try repository.load() == workspace else { throw LedgerError.invalid("Persistence check failed.") }
    let pdf = originals.appendingPathComponent(workspace.statements[0].storedFilename)
    let extracted = try PDFExtractor.read(url: pdf)
    guard extracted.bank == .hsbc, !extracted.lines.isEmpty else { throw LedgerError.invalid("PDF extraction check failed.") }
    let ocr = try PDFExtractor.read(url: pdf, forceOCR: true)
    guard ocr.lines.contains(where: \.ocr), !ocr.lines.isEmpty else { throw LedgerError.invalid("Local OCR check failed.") }
    let backup = root.appendingPathComponent("check.hkledger")
    try WorkspaceBackup.write(workspace, documents: originals, destination: backup)
    guard try WorkspaceBackup.read(backup) == workspace else { throw LedgerError.invalid("Backup check failed.") }
    guard try CSV.read(Exports.transactions(workspace)).count == 5 else { throw LedgerError.invalid("Export check failed.") }
    let testKeyStore = APIKeyStore(service: "hk.local.StatementManager.SelfCheck." + UUID().uuidString)
    defer { try? testKeyStore.remove() }
    try testKeyStore.save("synthetic-self-check-key")
    guard try testKeyStore.read() == "synthetic-self-check-key" else { throw LedgerError.invalid("Keychain round-trip failed.") }
    try testKeyStore.save("synthetic-updated-key")
    guard try testKeyStore.read() == "synthetic-updated-key" else { throw LedgerError.invalid("Keychain update failed.") }
    try testKeyStore.remove()
    guard !testKeyStore.containsKey() else { throw LedgerError.invalid("Keychain removal failed.") }
    print("PASS: Keychain storage, local-only self-check; sandboxed local PDF extraction, Vision OCR, SwiftData persistence, invoice allocations, CSV export, and backup restore.")
}
