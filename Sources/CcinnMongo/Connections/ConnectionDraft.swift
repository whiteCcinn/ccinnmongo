import Foundation
import CcinnMongoKit
import MongoKit
import Observation

/// Editable copy of a profile with a two-way URI ⇄ form binding and connection testing.
@MainActor
@Observable
final class ConnectionDraft {
    enum TestState: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)
    }

    let profileID: UUID?
    /// The saved profile being edited (nil for a new connection), for bookkeeping the editor does not show.
    private let original: ConnectionProfile?
    var name: String
    var color: ProfileColor
    var isFavorite: Bool
    var allowLegacyTLS: Bool
    var sshEnabled: Bool
    var ssh: SSHTunnelConfiguration
    var sshSecret: String
    var mcpAccess: MCPAccessLevel

    /// Structured form; the source of truth.
    var form: ConnectionForm {
        // Form edits rewrite the URI, but URI edits must never rewrite the text being typed.
        didSet { if !isUpdatingFromURI { syncURIFromForm() } }
    }

    /// URI text shown to the user (password masked as ****).
    var uriText: String = "" {
        didSet {
            guard !isWritingURI, uriText != oldValue else { return }
            syncFormFromURI()
        }
    }

    var uriError: String?
    var testState: TestState = .idle
    private var isWritingURI = false
    private var isUpdatingFromURI = false
    private var testTask: Task<Void, Never>?

    static let maskedPassword = "****"

    init(profile: ConnectionProfile?, store: ProfileStore) {
        profileID = profile?.id
        original = profile
        name = profile?.name ?? ""
        color = profile?.color ?? .green
        isFavorite = profile?.isFavorite ?? false
        allowLegacyTLS = profile?.allowLegacyTLS ?? false
        sshEnabled = profile?.ssh != nil
        ssh = profile?.ssh ?? SSHTunnelConfiguration(host: "", username: NSUserName(), authentication: .agent)
        sshSecret = profile.flatMap { store.sshSecret(for: $0) } ?? ""
        mcpAccess = profile?.mcpAccess ?? .disabled
        if let profile, let uri = try? store.connectionString(for: profile) {
            form = ConnectionForm(uri)
        } else {
            form = (try? ConnectionForm(uri: "mongodb://localhost:27017/")) ?? ConnectionForm()
        }
        syncURIFromForm()
    }

    /// The full connection string including the real password.
    var connectionString: ConnectionString { form.uri }

    var isValid: Bool { uriError == nil && !form.hosts.filter { !$0.host.isEmpty }.isEmpty }

    func makeProfile() -> ConnectionProfile {
        var profile = ConnectionProfile(id: profileID ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), uri: form.uri.description,
                                        color: color, isFavorite: isFavorite, ssh: sshEnabled ? ssh : nil, allowLegacyTLS: allowLegacyTLS,
                                        mcpAccess: mcpAccess)
        if let original { profile.preserveHistory(from: original) }
        return profile
    }

    // MARK: Sync

    private func syncURIFromForm() {
        var display = form.uri
        if display.password != nil { display.password = Self.maskedPassword }
        if display.tlsCertificateKeyFilePassword != nil { display.setOption("tlsCertificateKeyFilePassword", Self.maskedPassword) }
        isWritingURI = true
        uriText = display.description
        isWritingURI = false
        uriError = nil
    }

    private func syncFormFromURI() {
        do {
            var parsed = try ConnectionString(uriText)
            // Keep the stored password when the masked placeholder is left untouched.
            if parsed.password == Self.maskedPassword { parsed.password = form.password.isEmpty ? nil : form.password }
            if parsed.tlsCertificateKeyFilePassword == Self.maskedPassword {
                parsed.setOption("tlsCertificateKeyFilePassword", form.tlsCertificateKeyFilePassword.isEmpty ? nil : form.tlsCertificateKeyFilePassword)
            }
            isUpdatingFromURI = true
            form = ConnectionForm(parsed)
            isUpdatingFromURI = false
            uriError = nil
        } catch {
            uriError = (error as? MongoError)?.message ?? error.localizedDescription
        }
    }

    // MARK: Testing

    func test() {
        testTask?.cancel()
        let uri = connectionString
        let ssh = sshEnabled ? ssh : nil
        let secret = sshSecret.isEmpty ? nil : sshSecret
        let legacy = allowLegacyTLS
        testState = .running("Connecting…")
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in
                if case .running = self.testState { self.testState = .running(status) }
            }
        }
        testTask = Task {
            do {
                let opened = try await ConnectionOpener.open(uri: uri, ssh: ssh, sshSecret: secret, allowLegacyTLS: legacy, progress: report)
                let info = opened.info
                await opened.close()
                guard !Task.isCancelled else { return }
                let topology = info.setName.map { "\(info.serverType.displayName) · \($0)" } ?? info.serverType.displayName
                self.testState = .succeeded("MongoDB \(info.version) · \(topology) · \(info.protocolName)")
            } catch {
                guard !Task.isCancelled else { return }
                self.testState = .failed(describe(error))
            }
        }
    }

    func cancelTest() {
        testTask?.cancel()
        testState = .idle
    }
}
