import Foundation
import MongoKit

/// Editable, form-shaped view of a connection string. `uri` always reflects the form, and
/// `init(_:)` maps every known option onto a field; unknown options are preserved verbatim.
public struct ConnectionForm: Equatable, Sendable {
    public struct Host: Equatable, Identifiable, Sendable {
        public let id: UUID
        public var host: String
        public var port: Int

        public init(id: UUID = UUID(), host: String, port: Int = ServerAddress.defaultPort) {
            self.id = id
            self.host = host
            self.port = port
        }
    }

    public enum Authentication: String, CaseIterable, Identifiable, Sendable {
        case none = "None"
        case automatic = "Username / Password"
        case scramSHA256 = "SCRAM-SHA-256"
        case scramSHA1 = "SCRAM-SHA-1"
        case mongoCR = "MONGODB-CR (legacy)"
        case plain = "LDAP (PLAIN)"

        public var id: String { rawValue }

        var mechanism: AuthMechanism? {
            switch self {
            case .none, .automatic: nil
            case .scramSHA256: .scramSHA256
            case .scramSHA1: .scramSHA1
            case .mongoCR: .mongoCR
            case .plain: .plain
            }
        }

        init(mechanism: AuthMechanism?) {
            switch mechanism {
            case nil: self = .automatic
            case .scramSHA256: self = .scramSHA256
            case .scramSHA1: self = .scramSHA1
            case .mongoCR: self = .mongoCR
            case .plain: self = .plain
            }
        }
    }

    public var isSRV = false
    public var hosts: [Host] = [Host(host: "localhost")]
    /// `nil` = automatic (direct for a single host without replica set).
    public var directConnection: Bool?
    public var authentication: Authentication = .none
    public var username = ""
    public var password = ""
    public var authSource = ""
    public var defaultDatabase = ""
    public var tlsEnabled = false
    public var tlsAllowInvalidCertificates = false
    public var tlsAllowInvalidHostnames = false
    public var tlsCAFile = ""
    public var tlsCertificateKeyFile = ""
    public var tlsCertificateKeyFilePassword = ""
    public var replicaSet = ""
    public var readPreference: ReadPreferenceMode = .primary
    public var appName = ""
    public var connectTimeoutMS: Int?
    public var socketTimeoutMS: Int?
    public var maxPoolSize: Int?
    public var extraOptions: [ConnectionString.Option] = []

    static let mappedOptions: Set<String> = [
        "replicaSet", "authSource", "authMechanism", "tls", "tlsAllowInvalidCertificates", "tlsAllowInvalidHostnames",
        "tlsCAFile", "tlsCertificateKeyFile", "tlsCertificateKeyFilePassword", "directConnection", "readPreference",
        "appName", "connectTimeoutMS", "socketTimeoutMS", "maxPoolSize",
    ]

    public init() {}

    public init(uri: String) throws {
        self.init(try ConnectionString(uri))
    }

    public init(_ uri: ConnectionString) {
        isSRV = uri.scheme == .srv
        hosts = uri.hosts.map { Host(host: $0.host, port: $0.port) }
        directConnection = uri.directConnection
        if let username = uri.username {
            self.username = username
            password = uri.password ?? ""
            authentication = Authentication(mechanism: uri.authMechanism.flatMap { AuthMechanism(rawValue: $0.uppercased()) })
        } else {
            authentication = .none
        }
        authSource = uri.authSource ?? ""
        defaultDatabase = uri.database ?? ""
        tlsEnabled = uri.tls
        tlsAllowInvalidCertificates = uri.tlsAllowInvalidCertificates
        tlsAllowInvalidHostnames = uri.tlsAllowInvalidHostnames
        tlsCAFile = uri.tlsCAFile ?? ""
        tlsCertificateKeyFile = uri.tlsCertificateKeyFile ?? ""
        tlsCertificateKeyFilePassword = uri.tlsCertificateKeyFilePassword ?? ""
        replicaSet = uri.replicaSet ?? ""
        readPreference = uri.readPreference
        appName = uri.appName ?? ""
        connectTimeoutMS = uri.connectTimeoutMS
        socketTimeoutMS = uri.socketTimeoutMS
        maxPoolSize = uri.maxPoolSize
        extraOptions = uri.options.filter { !Self.mappedOptions.contains($0.name) }
    }

    public var uri: ConnectionString {
        var uri = ConnectionString(scheme: isSRV ? .srv : .standard,
                                   hosts: hosts.filter { !$0.host.isEmpty }.map { ServerAddress(host: $0.host.trimmingCharacters(in: .whitespaces), port: $0.port) },
                                   database: defaultDatabase.isEmpty ? nil : defaultDatabase)
        if uri.hosts.isEmpty { uri.hosts = [ServerAddress(host: "localhost")] }

        if authentication != .none, !username.isEmpty {
            uri.username = username
            uri.password = password.isEmpty ? nil : password
        }
        func set(_ name: String, _ value: String?) {
            if let value, !value.isEmpty { uri.setOption(name, value) }
        }
        set("replicaSet", replicaSet)
        if authentication != .none {
            set("authSource", authSource)
            set("authMechanism", authentication.mechanism?.rawValue)
        }
        if isSRV {
            if !tlsEnabled { set("tls", "false") }
        } else if tlsEnabled {
            set("tls", "true")
        }
        if tlsEnabled {
            if tlsAllowInvalidCertificates { set("tlsAllowInvalidCertificates", "true") }
            if tlsAllowInvalidHostnames { set("tlsAllowInvalidHostnames", "true") }
            set("tlsCAFile", tlsCAFile)
            set("tlsCertificateKeyFile", tlsCertificateKeyFile)
            set("tlsCertificateKeyFilePassword", tlsCertificateKeyFilePassword)
        }
        if let directConnection { set("directConnection", directConnection ? "true" : "false") }
        if readPreference != .primary { set("readPreference", readPreference.rawValue) }
        set("appName", appName)
        set("connectTimeoutMS", connectTimeoutMS.map(String.init))
        set("socketTimeoutMS", socketTimeoutMS.map(String.init))
        set("maxPoolSize", maxPoolSize.map(String.init))
        for option in extraOptions { uri.setOption(option.name, option.value) }
        return uri
    }
}
