import Foundation
import Network
import os
import Security

/// `MongoTransport` over Network.framework (TCP, optional TLS, Unix sockets).
final class NetworkTransport: MongoTransport, @unchecked Sendable {
    // NWConnection is thread-safe; the only mutable state we own is the one-shot resume guard used
    // during connect, protected by its own lock.
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let address: ServerAddress
    private let socketTimeout: Double?

    private init(connection: NWConnection, queue: DispatchQueue, address: ServerAddress, socketTimeout: Double?) {
        self.connection = connection
        self.queue = queue
        self.address = address
        self.socketTimeout = socketTimeout
    }

    static let factory: TransportFactory = { address, options in
        try await NetworkTransport.connect(to: address, options: options)
    }

    static func connect(to address: ServerAddress, options: TransportOptions) async throws -> NetworkTransport {
        let parameters = try makeParameters(for: address, options: options)
        let endpoint: NWEndpoint
        if address.isUnixSocket {
            endpoint = .unix(path: address.host)
        } else {
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: address.port)) else {
                throw MongoError(.invalidArgument, "Invalid port \(address.port)")
            }
            endpoint = .hostPort(host: NWEndpoint.Host(address.host), port: port)
        }
        let queue = DispatchQueue(label: "grove.transport.\(address)", qos: .userInitiated)
        let connection = NWConnection(to: endpoint, using: parameters)
        let transport = NetworkTransport(connection: connection, queue: queue, address: address, socketTimeout: options.socketTimeout)
        try await transport.start(timeout: options.connectTimeout, usesTLS: options.tls != nil)
        return transport
    }

    private func start(timeout: Double, usesTLS: Bool) async throws {
        let once = OSAllocatedUnfairLock(initialState: false)
        let address = self.address
        let connection = self.connection
        let queue = self.queue

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                @Sendable func finish(_ result: Result<Void, MongoError>) {
                    let first = once.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    guard first else { return }
                    connection.stateUpdateHandler = nil
                    switch result {
                    case .success: continuation.resume()
                    case let .failure(error):
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(.success(()))
                    case let .failed(error):
                        finish(.failure(Self.describe(error, address: address, tls: usesTLS)))
                    case let .waiting(error):
                        // Network.framework would keep retrying (e.g. connection refused); fail fast instead.
                        finish(.failure(Self.describe(error, address: address, tls: usesTLS)))
                    case .cancelled:
                        finish(.failure(MongoError(.cancelled, "Connection to \(address) was cancelled")))
                    default:
                        break
                    }
                }
                queue.asyncAfter(deadline: .now() + max(0.5, timeout)) {
                    finish(.failure(MongoError(.timeout, "Timed out after \(Int(timeout))s connecting to \(address)")))
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        let connection = self.connection
        let address = self.address
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MongoError(.network, "Failed to send to \(address): \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> [UInt8] {
        let connection = self.connection
        let address = self.address
        let timeout = socketTimeout
        let queue = self.queue
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
            let timer = ReadTimer(timeout: timeout, queue: queue) { connection.cancel() }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { data, _, isComplete, error in
                timer.cancel()
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if let error {
                    if case .posix(.ECANCELED) = error, let timeout {
                        continuation.resume(throwing: MongoError(.timeout, "No reply from \(address) within \(Int(timeout))s"))
                    } else {
                        continuation.resume(throwing: MongoError(.network, "Connection to \(address) failed: \(error.localizedDescription)"))
                    }
                } else if isComplete {
                    continuation.resume(throwing: MongoError(.connectionClosed, "\(address) closed the connection"))
                } else {
                    continuation.resume(throwing: MongoError(.network, "Connection to \(address) returned no data"))
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }

    // MARK: Parameters

    private static func makeParameters(for address: ServerAddress, options: TransportOptions) throws -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 120
        tcp.connectionTimeout = Int(max(1, options.connectTimeout.rounded(.up)))

        guard let tlsOptions = options.tls else {
            return NWParameters(tls: nil, tcp: tcp)
        }
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        if tlsOptions.allowLegacyProtocols {
            // TLS 1.0 (0x0301), spelled numerically because the named constant is deprecated.
            sec_protocol_options_set_min_tls_protocol_version(security, tls_protocol_version_t(rawValue: 0x0301) ?? .TLSv12)
        }
        if let file = tlsOptions.clientCertificateFile {
            let identity = try TLSMaterial.loadIdentity(pkcs12Path: file, password: tlsOptions.clientCertificatePassword)
            guard let secIdentity = sec_identity_create(identity) else {
                throw MongoError(.tls, "Could not use the client certificate in \(file)")
            }
            sec_protocol_options_set_local_identity(security, secIdentity)
        }

        let anchors = try tlsOptions.caFile.map(TLSMaterial.loadCertificates(pemPath:))
        if tlsOptions.allowInvalidCertificates || tlsOptions.allowInvalidHostnames || anchors != nil {
            let allowInvalidCertificates = tlsOptions.allowInvalidCertificates
            let allowInvalidHostnames = tlsOptions.allowInvalidHostnames
            let host = address.host
            sec_protocol_options_set_verify_block(security, { _, trustRef, complete in
                if allowInvalidCertificates {
                    complete(true)
                    return
                }
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                if let anchors {
                    SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                    SecTrustSetAnchorCertificatesOnly(trust, true)
                }
                let policy = allowInvalidHostnames ? SecPolicyCreateBasicX509() : SecPolicyCreateSSL(true, host as CFString)
                SecTrustSetPolicies(trust, policy)
                complete(SecTrustEvaluateWithError(trust, nil))
            }, DispatchQueue.global(qos: .userInitiated))
        }
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func describe(_ error: NWError, address: ServerAddress, tls: Bool) -> MongoError {
        switch error {
        case let .posix(code):
            switch code {
            case .ECONNREFUSED:
                return MongoError(.network, "Connection refused by \(address). Is mongod running and listening on that port?")
            case .ETIMEDOUT:
                return MongoError(.timeout, "Timed out connecting to \(address)")
            case .EHOSTUNREACH, .ENETUNREACH:
                return MongoError(.network, "\(address) is unreachable from this network")
            default:
                return MongoError(.network, "Could not connect to \(address): \(error.localizedDescription)")
            }
        case .dns:
            return MongoError(.dns, "Could not resolve host \(address.host)")
        case .tls:
            return MongoError(.tls, "TLS handshake with \(address) failed: \(error.localizedDescription)")
        default:
            return MongoError(tls ? .tls : .network, "Could not connect to \(address): \(error.localizedDescription)")
        }
    }
}

/// Cancels the connection if a read does not complete in time. `DispatchWorkItem` is thread-safe
/// for `cancel()`, so sharing it across the receive callback is sound.
private struct ReadTimer: @unchecked Sendable {
    private let item: DispatchWorkItem?

    init(timeout: Double?, queue: DispatchQueue, onTimeout: @escaping @Sendable () -> Void) {
        guard let timeout, timeout > 0 else {
            item = nil
            return
        }
        let item = DispatchWorkItem(block: onTimeout)
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
        self.item = item
    }

    func cancel() { item?.cancel() }
}

enum TLSMaterial {
    static func loadCertificates(pemPath path: String) throws -> [SecCertificate] {
        let expanded = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw MongoError(.tls, "Cannot read CA file \(path)")
        }
        var certificates: [SecCertificate] = []
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var remainder = Substring(text)
        while let start = remainder.range(of: begin), let finish = remainder.range(of: end, range: start.upperBound..<remainder.endIndex) {
            let base64 = remainder[start.upperBound..<finish.lowerBound].filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: String(base64)), let certificate = SecCertificateCreateWithData(nil, data as CFData) {
                certificates.append(certificate)
            }
            remainder = remainder[finish.upperBound...]
        }
        if certificates.isEmpty, let data = FileManager.default.contents(atPath: expanded),
           let certificate = SecCertificateCreateWithData(nil, data as CFData) {
            certificates.append(certificate) // DER
        }
        guard !certificates.isEmpty else { throw MongoError(.tls, "No certificates found in \(path)") }
        return certificates
    }

    static func loadIdentity(pkcs12Path path: String, password: String?) throws -> SecIdentity {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw MongoError(.tls, "Cannot read client certificate \(path)")
        }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password ?? ""] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityValue = first[kSecImportItemIdentity as String] else {
            throw MongoError(.tls, "Could not import \(path) (status \(status)). Provide a PKCS#12 (.p12) file and its password.")
        }
        let identityRef = identityValue as CFTypeRef
        guard CFGetTypeID(identityRef) == SecIdentityGetTypeID() else {
            throw MongoError(.tls, "\(path) does not contain a client identity")
        }
        // The type id was verified above, so this CF downcast cannot fail.
        return identityRef as! SecIdentity // swiftlint:disable:this force_cast
    }
}
