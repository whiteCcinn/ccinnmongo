import CcinnMongoKit
import Foundation
import Observation
import SwiftUI

/// Settings keys for the AI assistant.
enum AISettings {
    static let provider = "ai.provider"
    static let claudeModel = "ai.model.claude"
    static let codexModel = "ai.model.codex"
    static let claudePath = "ai.path.claude"
    static let codexPath = "ai.path.codex"
    static let includeSamples = "ai.includeSamples"
    static let allowQueries = "ai.allowQueries"
}

/// Discovers installed agent CLIs and creates configured agents.
@MainActor
@Observable
final class AgentService {
    static let shared = AgentService()

    private(set) var executables: [AgentProvider: URL] = [:]
    private(set) var searchPath = ""
    private(set) var hasScanned = false
    private(set) var isScanning = false

    var availableProviders: [AgentProvider] { AgentProvider.allCases.filter { executables[$0] != nil } }

    /// Preferred provider: the one chosen in Settings if installed, otherwise the first installed one.
    var activeProvider: AgentProvider? {
        let raw = UserDefaults.standard.string(forKey: AISettings.provider)
        if let raw, let chosen = AgentProvider(rawValue: raw), executables[chosen] != nil { return chosen }
        return availableProviders.first
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let overrides = [AgentProvider.claudeCode: UserDefaults.standard.string(forKey: AISettings.claudePath),
                         AgentProvider.codex: UserDefaults.standard.string(forKey: AISettings.codexPath)]
        Task.detached(priority: .userInitiated) {
            let path = AgentLocator.loginShellPath()
            var found: [AgentProvider: URL] = [:]
            for provider in AgentProvider.allCases {
                if let url = AgentLocator.locate(provider, override: overrides[provider] ?? nil, searchPath: path) { found[provider] = url }
            }
            await MainActor.run {
                self.executables = found
                self.searchPath = path
                self.hasScanned = true
                self.isScanning = false
            }
        }
    }

    func scanIfNeeded() {
        if !hasScanned { refresh() }
    }

    func agent(for provider: AgentProvider? = nil) throws -> CLIAgent {
        guard let provider = provider ?? activeProvider else { throw AgentError.notInstalled(.claudeCode) }
        guard let executable = executables[provider] else { throw AgentError.notInstalled(provider) }
        let modelKey = provider == .claudeCode ? AISettings.claudeModel : AISettings.codexModel
        let model = UserDefaults.standard.string(forKey: modelKey)
        return CLIAgent(provider: provider, executable: executable, model: model, searchPath: searchPath)
    }
}

/// Privacy statement shown wherever the assistant is used.
struct AIPrivacyNote: View {
    let provider: AgentProvider?

    var body: some View {
        Label {
            Text("Your question, field names\(UserDefaults.standard.bool(forKey: AISettings.includeSamples) ? ", sample documents" : "") and results of read-only queries are sent to \(provider.map(vendor) ?? "the selected assistant"). Connection details and passwords never leave CcinnMongo.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func vendor(_ provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode: "Claude Code (Anthropic)"
        case .codex: "Codex (OpenAI)"
        }
    }
}
