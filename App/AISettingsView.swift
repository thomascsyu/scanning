import SwiftUI
import StatementCore

@MainActor @Observable final class AISettings {
    private let defaults: UserDefaults
    let keyStore: APIKeyStore
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "deepSeekEnabled") } }
    var hasKey: Bool
    init() {
        let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        defaults = isDemo ? UserDefaults(suiteName: "hk.local.StatementManager.DemoAI")! : .standard
        keyStore = APIKeyStore(service: isDemo ? "hk.local.StatementManager.DeepSeek.Demo" : "hk.local.StatementManager.DeepSeek")
        enabled = defaults.bool(forKey: "deepSeekEnabled"); hasKey = keyStore.containsKey()
    }
    func saveKey(_ key: String) throws { try keyStore.save(key); hasKey = true }
    func removeKey() throws { try keyStore.remove(); hasKey = false; enabled = false }
}
struct AISettingsView: View {
    @Bindable var settings: AISettings
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var status: String?
    @State private var failed = false
    @State private var task: Task<Void, Never>?
    @State private var testing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("AI Settings", systemImage: "sparkles").font(.title2.bold())
            LabeledContent("Provider", value: "DeepSeek")
            LabeledContent("Model", value: DeepSeekClient.model)
            LabeledContent("API endpoint", value: DeepSeekClient.baseURL)
            Toggle("Enable DeepSeek assistance", isOn: $settings.enabled)
            Text("AI is optional. When you choose Suggest category in transaction review, the description, incoming/outgoing direction, HKD currency, and category names are sent to DeepSeek. Descriptions may contain client names or references. PDFs, balances, exact amounts, dates, and your invoice register are not uploaded.").font(.callout).foregroundStyle(.secondary)
            SecureField(settings.hasKey ? "Paste a replacement API key" : "Paste your DeepSeek API key", text: $key).textFieldStyle(.roundedBorder)
            HStack {
                Label(settings.hasKey ? "API key saved in macOS Keychain" : "No API key saved", systemImage: settings.hasKey ? "key.fill" : "key").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save key") { saveKey() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                Button("Remove key", role: .destructive) { do { try settings.removeKey(); key = ""; status = "API key removed. AI assistance is off."; failed = false } catch { fail(error) } }.disabled(!settings.hasKey || testing)
            }
            Text("The key stays out of workspace backups and exports. Requests use your DeepSeek API account; API charges may apply. Nothing is sent automatically during imports.").font(.caption).foregroundStyle(.secondary)
            if let status { Text(status).font(.callout).foregroundStyle(failed ? Color.red : Color.secondary).textSelection(.enabled) }
            HStack {
                Link("DeepSeek API documentation", destination: URL(string: "https://api-docs.deepseek.com/")!)
                Spacer()
                if testing { ProgressView().controlSize(.small); Button("Cancel test") { task?.cancel() } }
                else { Button("Test connection") { testConnection() }.disabled(!settings.hasKey || !key.isEmpty) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Test connection checks model access using the saved key; it sends no transaction data.").font(.caption2).foregroundStyle(.secondary)
        }.padding(24).frame(width: 660)
        .onDisappear { task?.cancel(); key = "" }
    }
    private func fail(_ error: Error) { status = error.localizedDescription; failed = true }
    private func saveKey() {
        do { try settings.saveKey(key); key = ""; status = "Key saved. Use Test connection to verify \(DeepSeekClient.model) access."; failed = false }
        catch { fail(error) }
    }
    private func testConnection() {
        testing = true; status = nil
        task = Task {
            defer { testing = false; task = nil }
            do { try await DeepSeekClient().checkConnection(apiKey: settings.keyStore.read()); status = "Connected. \(DeepSeekClient.model) is available for this API key."; failed = false }
            catch is CancellationError { status = "Connection test cancelled."; failed = false }
            catch { fail(error) }
        }
    }
}
struct AISuggestionPanel: View {
    @Bindable var settings: AISettings
    var description: String
    var direction: RuleDirection
    var categories: [String]
    var apply: (AISuggestion) -> Void
    @State private var showSettings = false
    @State private var suggestion: AISuggestion?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var working = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("DeepSeek · \(DeepSeekClient.model)", systemImage: "sparkles").font(.caption.bold())
                    Spacer()
                    Button("AI Settings…") { showSettings = true }.font(.caption)
                }
                if settings.enabled && settings.hasKey {
                    Text("Suggest category sends this description, direction, and category list to DeepSeek. Review before applying.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(working ? "Asking DeepSeek…" : "Suggest category") { ask() }.disabled(working || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if working { ProgressView().controlSize(.small); Button("Cancel") { task?.cancel() } }
                    }
                } else { Text("Add your API key and enable assistance in AI Settings to request a category suggestion.").font(.caption).foregroundStyle(.secondary) }
                if let suggestion {
                    Text("\(suggestion.category) · \(suggestion.transactionType.displayTitle)").font(.callout.bold())
                    Text(suggestion.explanation).font(.caption).textSelection(.enabled)
                    Button("Use suggestion") { apply(suggestion); self.suggestion = nil }.disabled(!categories.contains(suggestion.category))
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
        .sheet(isPresented: $showSettings) { AISettingsView(settings: settings) }
        .onChange(of: description) { _, _ in reset() }
        .onChange(of: direction) { _, _ in reset() }
        .onChange(of: categories) { _, _ in reset() }
        .onChange(of: settings.enabled) { _, enabled in if !enabled { reset() } }
        .onDisappear { task?.cancel() }
    }
    private func reset() { task?.cancel(); suggestion = nil; error = nil }
    private func ask() {
        guard settings.enabled, settings.hasKey else { return }
        let description = description, direction = direction, categories = categories
        working = true; suggestion = nil; error = nil
        task = Task {
            defer { working = false; task = nil }
            do {
                let result = try await DeepSeekClient().suggest(description: description, direction: direction, categories: categories, apiKey: settings.keyStore.read())
                try Task.checkCancellation()
                guard settings.enabled else { return }
                suggestion = result
            } catch is CancellationError { /* No suggestion from a cancelled or outdated request. */ }
            catch { self.error = error.localizedDescription }
        }
    }
}
