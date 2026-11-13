import Foundation

/// A bidirectional byte stream to one server. Implementations must make `close()` safe to call
/// from any thread at any time (it is used for cancellation) and make pending calls fail promptly.
public protocol MongoTransport: AnyObject, Sendable {
    func send(_ bytes: [UInt8]) async throws
    /// Returns the next chunk of bytes (at least one byte) or throws when the stream ends.
    func receive() async throws -> [UInt8]
    func close()
}

public struct TLSOptions: Sendable, Equatable {
    public var allowInvalidCertificates = false
    public var allowInvalidHostnames = false
    /// PEM file with one or more CA certificates to trust instead of the system roots.
    public var caFile: String?
    /// PKCS#12 file with the client certificate and private key.
    public var clientCertificateFile: String?
    public var clientCertificatePassword: String?
    /// Permit TLS 1.0/1.1 for very old servers.
    public var allowLegacyProtocols = false

    public init(allowInvalidCertificates: Bool = false, allowInvalidHostnames: Bool = false, caFile: String? = nil,
                clientCertificateFile: String? = nil, clientCertificatePassword: String? = nil, allowLegacyProtocols: Bool = false) {
        self.allowInvalidCertificates = allowInvalidCertificates
        self.allowInvalidHostnames = allowInvalidHostnames
        self.caFile = caFile
        self.clientCertificateFile = clientCertificateFile
        self.clientCertificatePassword = clientCertificatePassword
        self.allowLegacyProtocols = allowLegacyProtocols
    }
}

public struct TransportOptions: Sendable, Equatable {
    /// Seconds to establish TCP (+TLS).
    public var connectTimeout: Double
    /// Seconds to wait for each read; `nil` waits indefinitely (server-side maxTimeMS bounds queries).
    public var socketTimeout: Double?
    public var tls: TLSOptions?

    public init(connectTimeout: Double = 10, socketTimeout: Double? = nil, tls: TLSOptions? = nil) {
        self.connectTimeout = connectTimeout
        self.socketTimeout = socketTimeout
        self.tls = tls
    }
}

public typealias TransportFactory = @Sendable (ServerAddress, TransportOptions) async throws -> any MongoTransport
