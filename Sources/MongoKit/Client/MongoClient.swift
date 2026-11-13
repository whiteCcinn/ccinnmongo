import BSON
import Foundation

public struct MongoClientOptions: Sendable {
    public var transportFactory: TransportFactory
    public var dnsResolver: any DNSResolving
    /// Permit TLS 1.0/1.1 for very old servers.
    public var allowLegacyTLS: Bool
    /// Overrides `maxPoolSize` from the URI (default 6).
    public var maxPoolSize: Int?

    public init(transportFactory: TransportFactory? = nil, dnsResolver: (any DNSResolving)? = nil,
                allowLegacyTLS: Bool = false, maxPoolSize: Int? = nil) {
        self.transportFactory = transportFactory ?? NetworkTransport.factory
        self.dnsResolver = dnsResolver ?? SystemDNSResolver()
        self.allowLegacyTLS = allowLegacyTLS
        self.maxPoolSize = maxPoolSize
    }
}

/// Stages reported while connecting, for progress UI.
public enum ConnectionStage: Sendable, Equatable {
    case resolvingSRV
    case selectingServer
    case authenticating
    case loadingServerInfo
}

/// Description of the server a client is talking to.
public struct ServerInfo: Sendable {
    public let address: ServerAddress
    public let hello: HelloResponse
    public let buildInfo: BSONDocument?
    public let seedList: [ServerAddress]

    public var capabilities: ServerCapabilities { ServerCapabilities(maxWireVersion: hello.maxWireVersion) }
    public var version: String { buildInfo?["version"]?.stringValue ?? capabilities.approximateVersion }
    public var serverType: ServerType { hello.serverType }
    public var setName: String? { hello.setName }
    public var members: [String] { hello.memberAddresses }
    public var protocolName: String { capabilities.protocolName }
    public var gitVersion: String? { buildInfo?["gitVersion"]?.stringValue }
    public var isEnterprise: Bool {
        buildInfo?["modules"]?.arrayValue?.contains(.string("enterprise")) ?? false
    }

    /// Major/minor version numbers parsed from `version`.
    public var versionComponents: (major: Int, minor: Int) {
        let parts = version.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
        return (parts.first ?? 0, parts.dropFirst().first ?? 0)
    }
}

/// Entry point for talking to a MongoDB deployment of any version from 2.6 to 8.x.
///
/// The client lazily selects a server, keeps one bounded connection pool for it, and re-selects
/// after network or "not primary" errors. All public methods are safe to call concurrently.
public final class MongoClient: Sendable {
    public let connectionString: ConnectionString
    let state: ClientState

    public init(_ connectionString: ConnectionString, options: MongoClientOptions = MongoClientOptions()) {
        self.connectionString = connectionString
        state = ClientState(connectionString: connectionString, options: options)
    }

    public convenience init(_ uri: String, options: MongoClientOptions = MongoClientOptions()) throws {
        self.init(try ConnectionString(uri), options: options)
    }

    /// Selects a server, authenticates and loads build information.
    @discardableResult
    public func connect(progress: (@Sendable (ConnectionStage) -> Void)? = nil) async throws -> ServerInfo {
        let server = try await state.server(progress: progress)
        progress?(.authenticating)
        // Opening one pooled connection performs authentication, surfacing credential errors now.
        let buildInfo = try await server.pool.withConnection { connection -> BSONDocument? in
            progress?(.loadingServerInfo)
            return try? await connection.runCommand(["buildInfo": 1], database: "admin")
        }
        let info = ServerInfo(address: server.address, hello: server.hello, buildInfo: buildInfo, seedList: server.seeds)
        await state.setServerInfo(info)
        return info
    }

    public var serverInfo: ServerInfo? {
        get async { await state.serverInfo }
    }

    /// Closes all pooled connections. The client can no longer be used afterwards.
    public func close() async {
        await state.close()
    }

    /// Runs `body` with a pooled connection. Reads are retried once on a fresh server selection
    /// after network or "not primary" errors (e.g. an idle socket closed by the server, failover).
    func withConnection<T: Sendable>(retryable: Bool,
                                     _ body: (MongoConnection, ServerCapabilities) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            let server = try await state.server(progress: nil)
            do {
                return try await server.pool.withConnection { connection in
                    try await body(connection, server.capabilities)
                }
            } catch let error as MongoError where error.isNetworkError || error.isNotPrimary {
                await state.invalidate(server)
                guard retryable, attempt < 2, !Task.isCancelled else { throw error }
            }
        }
    }
}

/// Server selection and pool lifecycle.
actor ClientState {
    struct SelectedServer: Sendable {
        let address: ServerAddress
        let hello: HelloResponse
        let pool: ConnectionPool
        let seeds: [ServerAddress]
        var capabilities: ServerCapabilities { ServerCapabilities(maxWireVersion: hello.maxWireVersion) }
    }

    private let connectionString: ConnectionString
    private let options: MongoClientOptions
    private var current: SelectedServer?
    private var selection: Task<SelectedServer, any Error>?
    private var isClosed = false
    private(set) var serverInfo: ServerInfo?

    init(connectionString: ConnectionString, options: MongoClientOptions) {
        self.connectionString = connectionString
        self.options = options
    }

    func setServerInfo(_ info: ServerInfo) { serverInfo = info }

    func server(progress: (@Sendable (ConnectionStage) -> Void)?) async throws -> SelectedServer {
        guard !isClosed else { throw MongoError(.connectionClosed, "The client has been closed") }
        if let current { return current }
        if let selection { return try await selection.value }

        let connectionString = self.connectionString
        let options = self.options
        let task = Task { try await Self.select(connectionString: connectionString, options: options, progress: progress) }
        selection = task
        do {
            let selected = try await task.value
            selection = nil
            if isClosed {
                await selected.pool.close()
                throw MongoError(.connectionClosed, "The client has been closed")
            }
            current = selected
            return selected
        } catch {
            selection = nil
            throw error
        }
    }

    func invalidate(_ server: SelectedServer) async {
        guard let current, current.pool === server.pool else { return }
        self.current = nil
        await server.pool.close()
    }

    func close() async {
        isClosed = true
        selection?.cancel()
        if let current {
            self.current = nil
            await current.pool.close()
        }
    }

    // MARK: Selection

    private static func select(connectionString: ConnectionString, options: MongoClientOptions,
                               progress: (@Sendable (ConnectionStage) -> Void)?) async throws -> SelectedServer {
        var uri = connectionString
        if uri.scheme == .srv, let host = uri.hosts.first?.host {
            progress?(.resolvingSRV)
            let resolved = try await SRVResolution.resolve(host: host, resolver: options.dnsResolver)
            uri.hosts = resolved.hosts
            for (name, value) in resolved.options where uri.option(name) == nil {
                uri.setOption(name, value)
            }
        }

        progress?(.selectingServer)
        let credential = try MongoCredential(connectionString: uri)
        var tls: TLSOptions?
        if uri.tls {
            tls = TLSOptions(allowInvalidCertificates: uri.tlsAllowInvalidCertificates,
                             allowInvalidHostnames: uri.tlsAllowInvalidHostnames,
                             caFile: uri.tlsCAFile,
                             clientCertificateFile: uri.tlsCertificateKeyFile,
                             clientCertificatePassword: uri.tlsCertificateKeyFilePassword,
                             allowLegacyProtocols: options.allowLegacyTLS)
        }
        let transportOptions = TransportOptions(connectTimeout: Double(uri.connectTimeoutMS ?? 10_000) / 1000,
                                                socketTimeout: uri.socketTimeoutMS.flatMap { $0 > 0 ? Double($0) / 1000 : nil },
                                                tls: tls)
        let factory = ConnectionFactory(transportFactory: options.transportFactory,
                                        transportOptions: transportOptions,
                                        credential: credential,
                                        appName: uri.appName ?? "CcinnMongo",
                                        readPreference: uri.readPreference)

        let selector = ServerSelector(seeds: uri.hosts,
                                      direct: uri.prefersDirectConnection,
                                      replicaSet: uri.replicaSet,
                                      readPreference: uri.readPreference,
                                      probe: { address in try await factory.probe(address) })
        let chosen = try await selector.select()
        let address = chosen.address
        let pool = ConnectionPool(address: address,
                                  maxSize: options.maxPoolSize ?? uri.maxPoolSize.flatMap { $0 > 0 ? $0 : nil } ?? 6,
                                  factory: { try await factory.makeConnection(to: address) })
        return SelectedServer(address: address, hello: chosen.hello, pool: pool, seeds: uri.hosts)
    }
}
