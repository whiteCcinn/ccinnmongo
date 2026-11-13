import Foundation

/// `host:port` (or a Unix-domain socket path).
public struct ServerAddress: Sendable, Hashable, CustomStringConvertible, Codable {
    public static let defaultPort = 27017

    public var host: String
    public var port: Int

    public init(host: String, port: Int = ServerAddress.defaultPort) {
        self.host = host
        self.port = port
    }

    public var isUnixSocket: Bool { host.hasPrefix("/") && host.hasSuffix(".sock") }
    public var isIPv6: Bool { host.contains(":") }

    public var description: String {
        if isUnixSocket { return host }
        return isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Parses `host`, `host:port`, `[v6]` or `[v6]:port` (already percent-decoded).
    public init(parsing text: String) throws {
        if text.hasPrefix("/") {
            guard text.hasSuffix(".sock") else {
                throw MongoError(.invalidConnectionString, "Unix socket path '\(text)' must end with .sock")
            }
            self.init(host: text, port: 0)
            return
        }
        var host: String
        var portText: String?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else {
                throw MongoError(.invalidConnectionString, "IPv6 address '\(text)' is missing ']'")
            }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else {
                    throw MongoError(.invalidConnectionString, "Unexpected characters after IPv6 address in '\(text)'")
                }
                portText = String(rest.dropFirst())
            }
        } else {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else {
                throw MongoError(.invalidConnectionString, "Host '\(text)' contains more than one ':'; wrap IPv6 addresses in brackets")
            }
            host = String(parts[0])
            if parts.count == 2 { portText = String(parts[1]) }
        }
        host = host.lowercased()
        guard !host.isEmpty else { throw MongoError(.invalidConnectionString, "Empty host name in '\(text)'") }
        var port = Self.defaultPort
        if let portText {
            guard let value = Int(portText), (1...65535).contains(value) else {
                throw MongoError(.invalidConnectionString, "Invalid port '\(portText)'; ports must be between 1 and 65535")
            }
            port = value
        }
        self.init(host: host, port: port)
    }
}

public enum ReadPreferenceMode: String, Sendable, CaseIterable, Codable {
    case primary
    case primaryPreferred
    case secondary
    case secondaryPreferred
    case nearest
}

/// A parsed `mongodb://` or `mongodb+srv://` connection string that can be edited and re-serialised.
public struct ConnectionString: Sendable, Equatable, CustomStringConvertible {
    public enum Scheme: String, Sendable {
        case standard = "mongodb"
        case srv = "mongodb+srv"
    }

    public struct Option: Sendable, Equatable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public var scheme: Scheme
    public var hosts: [ServerAddress]
    public var username: String?
    public var password: String?
    /// Default database from the URI path.
    public var database: String?
    public private(set) var options: [Option]

    public init(scheme: Scheme = .standard, hosts: [ServerAddress], username: String? = nil, password: String? = nil,
                database: String? = nil, options: [Option] = []) {
        self.scheme = scheme
        self.hosts = hosts
        self.username = username
        self.password = password
        self.database = database
        self.options = options
    }

    public init(_ string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else {
            throw MongoError(.invalidConnectionString, "Connection strings must start with mongodb:// or mongodb+srv://")
        }
        guard let scheme = Scheme(rawValue: String(trimmed[..<schemeEnd.lowerBound]).lowercased()) else {
            throw MongoError(.invalidConnectionString, "Invalid scheme '\(trimmed[..<schemeEnd.lowerBound])': the scheme must be mongodb or mongodb+srv")
        }
        var rest = String(trimmed[schemeEnd.upperBound...])

        // Split off the query string first (it may contain '/', '@').
        var query = ""
        if let questionMark = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: questionMark)...])
            rest = String(rest[..<questionMark])
        }

        // userinfo is everything before the last '@' of the authority section.
        var authority = rest
        var path: String?
        // '/' separates the host list from the database; percent-encoded unix sockets contain no raw '/'.
        if let slash = rest.firstIndex(of: "/") {
            authority = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
        }

        var username: String?
        var password: String?
        if let at = authority.lastIndex(of: "@") {
            let userInfo = String(authority[..<at])
            authority = String(authority[authority.index(after: at)...])
            let parts = userInfo.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else {
                throw MongoError(.invalidConnectionString, "Username and password must be percent-encoded (found an unescaped ':')")
            }
            username = try Self.decode(String(parts[0]), component: "username")
            if parts.count == 2 { password = try Self.decode(String(parts[1]), component: "password") }
            if username?.isEmpty == true {
                throw MongoError(.invalidConnectionString, "The username must not be empty")
            }
        }

        guard !authority.isEmpty else {
            throw MongoError(.invalidConnectionString, "The connection string has no host")
        }
        var hosts: [ServerAddress] = []
        for hostText in authority.split(separator: ",", omittingEmptySubsequences: false) {
            let decoded = try Self.decode(String(hostText), component: "host")
            if scheme == .srv, decoded.contains(":") {
                throw MongoError(.invalidConnectionString, "mongodb+srv:// URIs must not specify a port")
            }
            hosts.append(try ServerAddress(parsing: decoded))
        }

        var database: String?
        if let path, !path.isEmpty {
            let decoded = try Self.decode(path, component: "database")
            let forbidden: Set<Character> = ["/", "\\", " ", "\"", "$"]
            guard !decoded.contains(where: { forbidden.contains($0) }) else {
                throw MongoError(.invalidConnectionString, "Database name '\(decoded)' contains an illegal character")
            }
            database = decoded
        }

        var options: [Option] = []
        for pair in query.split(separator: "&") where !pair.isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw MongoError(.invalidConnectionString, "Option '\(pair)' has no value")
            }
            let name = Self.canonicalOptionName(try Self.decode(String(parts[0]), component: "option name"))
            let value = try Self.decode(String(parts[1]), component: "option value")
            options.removeAll { $0.name == name }
            options.append(Option(name: name, value: value))
        }

        self.init(scheme: scheme, hosts: hosts, username: username, password: password, database: database, options: options)
        try validate()
    }

    private func validate() throws {
        if scheme == .srv, hosts.count != 1 {
            throw MongoError(.invalidConnectionString, "mongodb+srv:// URIs must contain exactly one host")
        }
        for name in ["tls", "tlsAllowInvalidCertificates", "tlsAllowInvalidHostnames", "tlsInsecure", "directConnection", "retryWrites", "retryReads", "loadBalanced", "journal"] {
            if let value = option(name), Self.parseBool(value) == nil {
                throw MongoError(.invalidConnectionString, "Option \(name) must be true or false, got '\(value)'")
            }
        }
        for name in ["connectTimeoutMS", "socketTimeoutMS", "serverSelectionTimeoutMS", "maxPoolSize", "minPoolSize", "maxIdleTimeMS", "localThresholdMS", "heartbeatFrequencyMS", "waitQueueTimeoutMS"] {
            if let value = option(name), Int(value).map({ $0 >= 0 }) != true {
                throw MongoError(.invalidConnectionString, "Option \(name) must be a non-negative integer, got '\(value)'")
            }
        }
        if let mode = option("readPreference"), ReadPreferenceMode(rawValue: mode) == nil {
            throw MongoError(.invalidConnectionString, "Unknown read preference '\(mode)'")
        }
    }

    // MARK: Options

    public func option(_ name: String) -> String? {
        let canonical = Self.canonicalOptionName(name)
        return options.first(where: { $0.name == canonical })?.value
    }

    /// Sets (or with `nil` removes) an option, keeping the position of existing options.
    public mutating func setOption(_ name: String, _ value: String?) {
        let canonical = Self.canonicalOptionName(name)
        if let index = options.firstIndex(where: { $0.name == canonical }) {
            if let value {
                options[index].value = value
            } else {
                options.remove(at: index)
            }
        } else if let value {
            options.append(Option(name: canonical, value: value))
        }
    }

    public var authSource: String? { option("authSource") }
    public var authMechanism: String? { option("authMechanism") }
    public var replicaSet: String? { option("replicaSet") }
    public var appName: String? { option("appName") }
    public var directConnection: Bool? { option("directConnection").flatMap(Self.parseBool) }
    public var readPreference: ReadPreferenceMode { option("readPreference").flatMap(ReadPreferenceMode.init) ?? .primary }
    public var tlsAllowInvalidCertificates: Bool {
        option("tlsAllowInvalidCertificates").flatMap(Self.parseBool) ?? option("tlsInsecure").flatMap(Self.parseBool) ?? false
    }
    public var tlsAllowInvalidHostnames: Bool {
        option("tlsAllowInvalidHostnames").flatMap(Self.parseBool) ?? option("tlsInsecure").flatMap(Self.parseBool) ?? false
    }
    public var tlsCAFile: String? { option("tlsCAFile") }
    public var tlsCertificateKeyFile: String? { option("tlsCertificateKeyFile") }
    public var tlsCertificateKeyFilePassword: String? { option("tlsCertificateKeyFilePassword") }
    public var connectTimeoutMS: Int? { option("connectTimeoutMS").flatMap(Int.init) }
    public var socketTimeoutMS: Int? { option("socketTimeoutMS").flatMap(Int.init) }
    public var serverSelectionTimeoutMS: Int? { option("serverSelectionTimeoutMS").flatMap(Int.init) }
    public var maxPoolSize: Int? { option("maxPoolSize").flatMap(Int.init) }

    /// TLS is on when requested explicitly, and by default for SRV URIs.
    public var tls: Bool {
        if let explicit = option("tls").flatMap(Self.parseBool) { return explicit }
        return scheme == .srv
    }

    public var authMechanismProperties: [String: String] {
        guard let raw = option("authMechanismProperties") else { return [:] }
        var result: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    /// One seed and no replica set (or `directConnection=true` with one host) ⇒ talk to that server directly.
    public var prefersDirectConnection: Bool {
        guard scheme == .standard, hosts.count == 1 else { return false }
        if let explicit = directConnection { return explicit }
        return replicaSet == nil
    }

    // MARK: Serialisation

    public var description: String { serialize(redactPassword: false) }

    /// Connection string safe for display and logs.
    public var redacted: String { serialize(redactPassword: true) }

    private func serialize(redactPassword: Bool) -> String {
        var output = scheme.rawValue + "://"
        if let username {
            output += Self.encode(username)
            if password != nil {
                output += ":" + (redactPassword ? "****" : Self.encode(password ?? ""))
            }
            output += "@"
        }
        output += hosts.map { address -> String in
            if address.isUnixSocket { return Self.encode(address.host) }
            if scheme == .srv { return address.host }
            return address.description
        }.joined(separator: ",")
        output += "/"
        if let database { output += Self.encode(database) }
        if !options.isEmpty {
            output += "?" + options.map { "\($0.name)=\(Self.encodeOptionValue($0.value))" }.joined(separator: "&")
        }
        return output
    }

    // MARK: Helpers

    static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1", "yes", "y", "t": true
        case "false", "0", "no", "n", "f": false
        default: nil
        }
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let unreservedForValues = unreserved.union(CharacterSet(charactersIn: ":,"))

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// Option values keep ':' and ',' readable (e.g. authMechanismProperties).
    static func encodeOptionValue(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreservedForValues) ?? text
    }

    static func decode(_ text: String, component: String) throws -> String {
        guard let decoded = text.removingPercentEncoding else {
            throw MongoError(.invalidConnectionString, "Invalid percent-encoding in \(component)")
        }
        return decoded
    }

    /// Canonical spelling of known options (option names are case-insensitive).
    static func canonicalOptionName(_ name: String) -> String {
        let lowered = name.lowercased()
        if lowered == "ssl" { return "tls" }
        return knownOptions[lowered] ?? name
    }

    private static let knownOptions: [String: String] = {
        let names = [
            "appName", "authMechanism", "authMechanismProperties", "authSource", "compressors", "connectTimeoutMS",
            "directConnection", "heartbeatFrequencyMS", "journal", "loadBalanced", "localThresholdMS", "maxIdleTimeMS",
            "maxPoolSize", "maxStalenessSeconds", "minPoolSize", "readConcernLevel", "readPreference", "readPreferenceTags",
            "replicaSet", "retryReads", "retryWrites", "serverSelectionTimeoutMS", "socketTimeoutMS", "srvMaxHosts",
            "srvServiceName", "tls", "tlsAllowInvalidCertificates", "tlsAllowInvalidHostnames", "tlsCAFile",
            "tlsCertificateKeyFile", "tlsCertificateKeyFilePassword", "tlsInsecure", "w", "waitQueueTimeoutMS",
            "wTimeoutMS", "zlibCompressionLevel", "uuidRepresentation",
        ]
        return Dictionary(uniqueKeysWithValues: names.map { ($0.lowercased(), $0) })
    }()
}
