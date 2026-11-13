import AppKit
import GroveKit
import MongoKit
import SwiftUI
import UniformTypeIdentifiers

/// Edits one connection: URI at the top, structured options below, test/save/connect actions.
struct ConnectionEditorView: View {
    @Bindable var draft: ConnectionDraft
    let store: ProfileStore
    let session: WindowSession
    let onSaved: (ConnectionProfile) -> Void

    @State private var section: Section = .general
    @State private var saveError: String?
    @State private var showPassword = false

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case authentication = "Authentication"
        case tls = "TLS / SSL"
        case ssh = "SSH Tunnel"
        case advanced = "Advanced"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "server.rack"
            case .authentication: "person.badge.key"
            case .tls: "lock"
            case .ssh: "lock.shield"
            case .advanced: "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    uriSection
                    Picker("", selection: $section) {
                        ForEach(Section.allCases) { section in
                            Label(section.rawValue, systemImage: section.icon).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Group {
                        switch section {
                        case .general: generalSection
                        case .authentication: authenticationSection
                        case .tls: tlsSection
                        case .ssh: sshSection
                        case .advanced: advancedSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.snappy, value: section)

                    testResult
                    if let saveError { ErrorBanner(message: saveError) { self.saveError = nil } }
                    if let error = session.connectError { ErrorBanner(message: error) { session.connectError = nil } }
                }
                .padding(28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            Divider()
            actionBar
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(Theme.color(for: draft.color).gradient)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "leaf.fill").foregroundStyle(.white).font(.system(size: 15, weight: .semibold)))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Connection name", text: $draft.name, prompt: Text(draft.form.hosts.first?.host ?? "Untitled connection"))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    ForEach(ProfileColor.allCases.filter { $0 != .none }) { color in
                        Button {
                            draft.color = color
                        } label: {
                            Circle()
                                .fill(Theme.color(for: color))
                                .frame(width: 13, height: 13)
                                .overlay(Circle().strokeBorder(.primary.opacity(draft.color == color ? 0.8 : 0), lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help(color.rawValue.capitalized)
                    }
                }
            }
            Spacer()
            Toggle(isOn: $draft.isFavorite) {
                Image(systemName: draft.isFavorite ? "star.fill" : "star")
            }
            .toggleStyle(.button)
            .help("Favorite")
        }
    }

    private var uriSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connection String").font(.headline)
            TextField("mongodb://user@host:27017/?authSource=admin", text: $draft.uriText, axis: .vertical)
                .font(Theme.monospaced)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius)
                    .strokeBorder(draft.uriError == nil ? Color.secondary.opacity(0.3) : Color.red.opacity(0.7)))
            if let error = draft.uriError {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            } else {
                Text("Edit the connection string directly or use the options below — both stay in sync. Passwords are stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sections

    private var generalSection: some View {
        Form {
            Picker("Scheme", selection: $draft.form.isSRV) {
                Text("mongodb://").tag(false)
                Text("mongodb+srv:// (DNS seed list)").tag(true)
            }
            ForEach($draft.form.hosts) { $host in
                HStack {
                    TextField("Host", text: $host.host, prompt: Text("hostname or IP"))
                    if !draft.form.isSRV {
                        TextField("Port", value: $host.port, format: .number.grouping(.never))
                            .frame(width: 80)
                    }
                    if draft.form.hosts.count > 1 {
                        Button {
                            draft.form.hosts.removeAll { $0.id == host.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !draft.form.isSRV {
                Button {
                    draft.form.hosts.append(.init(host: ""))
                } label: {
                    Label("Add host", systemImage: "plus")
                }
                .buttonStyle(.link)
                Picker("Direct connection", selection: $draft.form.directConnection) {
                    Text("Automatic").tag(Bool?.none)
                    Text("Yes — connect only to this host").tag(Bool?.some(true))
                    Text("No — discover the replica set").tag(Bool?.some(false))
                }
            }
            TextField("Default database", text: $draft.form.defaultDatabase, prompt: Text("optional"))
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var authenticationSection: some View {
        Form {
            Picker("Method", selection: $draft.form.authentication) {
                ForEach(ConnectionForm.Authentication.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            if draft.form.authentication != .none {
                TextField("Username", text: $draft.form.username)
                HStack {
                    Group {
                        if showPassword {
                            TextField("Password", text: $draft.form.password)
                        } else {
                            SecureField("Password", text: $draft.form.password)
                        }
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                TextField("Authentication database", text: $draft.form.authSource, prompt: Text(draft.form.authentication == .plain ? "$external" : "admin"))
                Text(authenticationHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var authenticationHint: String {
        switch draft.form.authentication {
        case .automatic: "Grove negotiates the mechanism: SCRAM-SHA-256 (4.0+), SCRAM-SHA-1 (3.0+) or MONGODB-CR (2.6)."
        case .mongoCR: "MONGODB-CR is the legacy mechanism used by MongoDB 2.6 and users created before the SCRAM upgrade."
        case .plain: "LDAP authentication sends the password to the server; use it only with TLS."
        default: ""
        }
    }

    private var tlsSection: some View {
        Form {
            Toggle("Use TLS/SSL", isOn: $draft.form.tlsEnabled)
            if draft.form.tlsEnabled {
                FilePickerRow(title: "Certificate authority (PEM)", path: $draft.form.tlsCAFile, types: [.data, .item])
                FilePickerRow(title: "Client certificate (PKCS#12)", path: $draft.form.tlsCertificateKeyFile, types: [.data, .item])
                if !draft.form.tlsCertificateKeyFile.isEmpty {
                    SecureField("Client certificate password", text: $draft.form.tlsCertificateKeyFilePassword)
                }
                Toggle("Allow invalid certificates", isOn: $draft.form.tlsAllowInvalidCertificates)
                Toggle("Allow invalid hostnames", isOn: $draft.form.tlsAllowInvalidHostnames)
                Toggle("Allow legacy TLS 1.0/1.1 (very old servers)", isOn: $draft.allowLegacyTLS)
                if draft.form.tlsAllowInvalidCertificates {
                    Label("Certificate validation is disabled. Only use this for development servers.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var sshSection: some View {
        Form {
            Toggle("Connect through an SSH tunnel", isOn: $draft.sshEnabled)
            if draft.sshEnabled {
                TextField("SSH host", text: $draft.ssh.host, prompt: Text("bastion.example.com"))
                TextField("SSH port", value: $draft.ssh.port, format: .number.grouping(.never))
                TextField("SSH user", text: $draft.ssh.username)
                Picker("Authentication", selection: $draft.ssh.authentication) {
                    Text("SSH agent / ~/.ssh/config").tag(SSHTunnelConfiguration.Authentication.agent)
                    Text("Password").tag(SSHTunnelConfiguration.Authentication.password)
                    Text("Private key").tag(SSHTunnelConfiguration.Authentication.privateKey)
                }
                switch draft.ssh.authentication {
                case .password:
                    SecureField("SSH password", text: $draft.sshSecret)
                case .privateKey:
                    FilePickerRow(title: "Private key", path: Binding(get: { draft.ssh.privateKeyPath ?? "" }, set: { draft.ssh.privateKeyPath = $0 }),
                                  types: [.item], startDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh"))
                    SecureField("Passphrase (optional)", text: $draft.sshSecret)
                case .agent:
                    EmptyView()
                }
                Text("Grove uses the system OpenSSH client, so your ~/.ssh/config, known hosts and agent work as in Terminal. MongoDB traffic is forwarded to the first host above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var advancedSection: some View {
        Form {
            TextField("Replica set name", text: $draft.form.replicaSet, prompt: Text("optional"))
            Picker("Read preference", selection: $draft.form.readPreference) {
                ForEach(ReadPreferenceMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            TextField("Application name", text: $draft.form.appName, prompt: Text("Grove"))
            TextField("Connect timeout (ms)", value: $draft.form.connectTimeoutMS, format: .number.grouping(.never), prompt: Text("10000"))
            TextField("Socket timeout (ms)", value: $draft.form.socketTimeoutMS, format: .number.grouping(.never), prompt: Text("none"))
            TextField("Max pool size", value: $draft.form.maxPoolSize, format: .number.grouping(.never), prompt: Text("6"))
            if !draft.form.extraOptions.isEmpty {
                LabeledContent("Other options") {
                    Text(draft.form.extraOptions.map { "\($0.name)=\($0.value)" }.joined(separator: "&"))
                        .font(Theme.monospacedSmall)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    @ViewBuilder
    private var testResult: some View {
        switch draft.testState {
        case .idle:
            EmptyView()
        case let .running(status):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { draft.cancelTest() }.buttonStyle(.borderless)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        case let .succeeded(message):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        case let .failed(message):
            ErrorBanner(message: message) { draft.testState = .idle }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack {
            Button {
                draft.test()
            } label: {
                Label("Test", systemImage: "bolt.horizontal.circle")
            }
            .disabled(!draft.isValid)
            Spacer()
            Button("Save") { _ = save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!draft.isValid)
            Button {
                if let profile = save() { session.connect(profile: profile, store: store) }
            } label: {
                Text(draft.profileID == nil ? "Save & Connect" : "Connect")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func save() -> ConnectionProfile? {
        do {
            let saved = try store.save(draft.makeProfile(), uri: draft.connectionString.description, sshSecret: draft.sshEnabled ? draft.sshSecret : nil)
            saveError = nil
            onSaved(saved)
            return saved
        } catch {
            saveError = (error as? MongoError)?.message ?? error.localizedDescription
            return nil
        }
    }
}

/// Text field with a "Choose…" button that opens a file panel.
struct FilePickerRow: View {
    let title: String
    @Binding var path: String
    var types: [UTType] = [.item]
    var startDirectory: URL?

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField("", text: $path, prompt: Text("none"))
                    .labelsHidden()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = types
                    panel.showsHiddenFiles = true
                    if let startDirectory { panel.directoryURL = startDirectory }
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
        }
    }
}
