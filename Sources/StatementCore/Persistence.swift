import Foundation
import SwiftData
import CryptoKit

@Model public final class StoredWorkspace {
    public var key: String = "primary"
    public var payload: Data = Data()
    public init(payload: Data) { self.payload = payload }
}
@MainActor public final class LedgerRepository {
    public let container: ModelContainer
    private let context: ModelContext
    private let record: StoredWorkspace
    public init(url: URL? = nil, inMemory: Bool = false) throws {
        let config: ModelConfiguration
        if let url { config = ModelConfiguration(url: url, cloudKitDatabase: .none) }
        else { config = ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none) }
        container = try ModelContainer(for: StoredWorkspace.self, configurations: config)
        context = ModelContext(container); context.autosaveEnabled = false
        if let existing = try context.fetch(FetchDescriptor<StoredWorkspace>()).first { record = existing }
        else { record = StoredWorkspace(payload: try JSONEncoder().encode(Workspace())); context.insert(record); try context.save() }
    }
    public func load() throws -> Workspace { let result = try JSONDecoder().decode(Workspace.self, from: record.payload); try result.validate(); return result }
    public func save(_ workspace: Workspace) throws {
        try workspace.validate()
        let previous = record.payload
        do { record.payload = try JSONEncoder().encode(workspace); try context.save() }
        catch { record.payload = previous; throw error }
    }
}
public enum WorkspaceBackup {
    public static func write(_ workspace: Workspace, documents: URL, destination: URL) throws {
        try workspace.validate()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw LedgerError.invalid("Choose a new backup folder name.") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let originals = destination.appendingPathComponent("Originals", isDirectory: true)
            try fm.createDirectory(at: originals, withIntermediateDirectories: true)
            for statement in workspace.statements {
                try fm.copyItem(at: documents.appendingPathComponent(statement.storedFilename), to: originals.appendingPathComponent(statement.storedFilename))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(workspace).write(to: destination.appendingPathComponent("workspace.json"), options: .atomic)
        } catch { try? fm.removeItem(at: destination); throw error }
    }
    public static func read(_ source: URL) throws -> Workspace {
        let state = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: source.appendingPathComponent("workspace.json")))
        try state.validate()
        for statement in state.statements {
            let data = try Data(contentsOf: source.appendingPathComponent("Originals").appendingPathComponent(statement.storedFilename))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == statement.hash else { throw LedgerError.invalid("Backup contains a missing or altered original PDF.") }
        }
        return state
    }
}
public enum OriginalsStore {
    /// Delete stored statement PDFs that no statement references any more (rolled-back imports, replaced
    /// workspaces). Only the app's own `<UUID>.pdf` copies are considered; anything else in the folder is left alone.
    /// Call it only when nothing else can still need a file, e.g. at launch before any undo history exists.
    @discardableResult
    public static func removeUnreferenced(in documents: URL, referenced: Set<String>) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: documents.path) else { return 0 }
        var removed = 0
        for name in names where !referenced.contains(name) && name.lowercased().hasSuffix(".pdf")
            && UUID(uuidString: String(name.dropLast(4))) != nil {
            if (try? fm.removeItem(at: documents.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
