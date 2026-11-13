import dnssd
import Foundation
import os

public struct SRVRecord: Sendable, Equatable {
    public var priority: UInt16
    public var weight: UInt16
    public var port: UInt16
    public var target: String

    public init(priority: UInt16 = 0, weight: UInt16 = 0, port: UInt16, target: String) {
        self.priority = priority
        self.weight = weight
        self.port = port
        self.target = target
    }
}

public protocol DNSResolving: Sendable {
    func srvRecords(for name: String) async throws -> [SRVRecord]
    /// Each TXT record with its character-strings concatenated.
    func txtRecords(for name: String) async throws -> [String]
}

/// DNS resolution through the system resolver (dnssd), honouring the user's DNS configuration and VPNs.
public struct SystemDNSResolver: DNSResolving {
    public init() {}

    public func srvRecords(for name: String) async throws -> [SRVRecord] {
        let records = try await Self.query(name: name, type: UInt16(kDNSServiceType_SRV))
        return records.compactMap(Self.parseSRV)
    }

    public func txtRecords(for name: String) async throws -> [String] {
        let records = try await Self.query(name: name, type: UInt16(kDNSServiceType_TXT))
        return records.map(Self.parseTXT)
    }

    // MARK: Parsing

    static func parseSRV(_ data: [UInt8]) -> SRVRecord? {
        guard data.count >= 7 else { return nil }
        let priority = UInt16(data[0]) << 8 | UInt16(data[1])
        let weight = UInt16(data[2]) << 8 | UInt16(data[3])
        let port = UInt16(data[4]) << 8 | UInt16(data[5])
        var labels: [String] = []
        var index = 6
        while index < data.count {
            let length = Int(data[index])
            index += 1
            if length == 0 { break }
            guard length < 64, index + length <= data.count else { return nil }
            labels.append(String(decoding: data[index..<(index + length)], as: UTF8.self))
            index += length
        }
        guard !labels.isEmpty else { return nil }
        return SRVRecord(priority: priority, weight: weight, port: port, target: labels.joined(separator: ".").lowercased())
    }

    static func parseTXT(_ data: [UInt8]) -> String {
        var result = ""
        var index = 0
        while index < data.count {
            let length = Int(data[index])
            index += 1
            let end = min(index + length, data.count)
            result += String(decoding: data[index..<end], as: UTF8.self)
            index = end
        }
        return result
    }

    // MARK: dnssd

    private final class QueryContext: @unchecked Sendable {
        // Mutated only on the thread that runs DNSServiceProcessResult.
        var records: [[UInt8]] = []
        var errorCode: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_NoError)
        var finished = false
    }

    private static func query(name: String, type: UInt16) async throws -> [[UInt8]] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try blockingQuery(name: name, type: type, timeout: 10) })
            }
        }
    }

    private static func blockingQuery(name: String, type: UInt16, timeout: TimeInterval) throws -> [[UInt8]] {
        let context = QueryContext()
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }

        var reference: DNSServiceRef?
        let callback: DNSServiceQueryRecordReply = { _, flags, _, errorCode, _, _, _, length, data, _, contextPointer in
            guard let contextPointer else { return }
            let context = Unmanaged<QueryContext>.fromOpaque(contextPointer).takeUnretainedValue()
            if errorCode != DNSServiceErrorType(kDNSServiceErr_NoError) {
                context.errorCode = errorCode
                context.finished = true
                return
            }
            if let data, length > 0 {
                let bytes = UnsafeRawBufferPointer(start: data, count: Int(length))
                context.records.append(Array(bytes))
            }
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
                context.finished = true
            }
        }

        let status = DNSServiceQueryRecord(&reference, DNSServiceFlags(kDNSServiceFlagsTimeout), 0, name, type,
                                           UInt16(kDNSServiceClass_IN), callback, unmanaged.toOpaque())
        guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let reference else {
            throw MongoError(.dns, "DNS query for \(name) failed (error \(status))")
        }
        defer { DNSServiceRefDeallocate(reference) }

        let socket = DNSServiceRefSockFD(reference)
        let deadline = Date().addingTimeInterval(timeout)
        while !context.finished {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw MongoError(.dns, "DNS query for \(name) timed out") }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            if ready > 0 {
                let processStatus = DNSServiceProcessResult(reference)
                guard processStatus == DNSServiceErrorType(kDNSServiceErr_NoError) else {
                    throw MongoError(.dns, "DNS query for \(name) failed (error \(processStatus))")
                }
            } else if ready < 0, errno != EINTR {
                throw MongoError(.dns, "DNS query for \(name) failed (poll error \(errno))")
            }
        }
        if context.errorCode == DNSServiceErrorType(kDNSServiceErr_NoSuchRecord) || context.errorCode == DNSServiceErrorType(kDNSServiceErr_NoSuchName) {
            return []
        }
        guard context.errorCode == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            if context.errorCode == DNSServiceErrorType(kDNSServiceErr_Timeout) {
                throw MongoError(.dns, "DNS query for \(name) timed out")
            }
            throw MongoError(.dns, "DNS query for \(name) failed (error \(context.errorCode))")
        }
        return context.records
    }
}

/// `mongodb+srv://` seed-list discovery and validation.
enum SRVResolution {
    struct Result: Sendable {
        var hosts: [ServerAddress]
        var options: [String: String]
    }

    static let allowedTXTOptions: Set<String> = ["authSource", "replicaSet", "loadBalanced"]

    static func resolve(host: String, resolver: any DNSResolving) async throws -> Result {
        let records = try await resolver.srvRecords(for: "_mongodb._tcp.\(host)")
        guard !records.isEmpty else {
            throw MongoError(.dns, "No SRV records found for _mongodb._tcp.\(host)")
        }
        var hosts: [ServerAddress] = []
        for record in records {
            let target = record.target.hasSuffix(".") ? String(record.target.dropLast()) : record.target
            guard isValidTarget(target, forSRVHost: host) else {
                throw MongoError(.dns, "SRV record \(target) is not in the domain of \(host); refusing to connect (possible DNS hijacking)")
            }
            hosts.append(ServerAddress(host: target.lowercased(), port: Int(record.port)))
        }

        let txt = try await resolver.txtRecords(for: host)
        guard txt.count <= 1 else { throw MongoError(.dns, "Multiple TXT records found for \(host); only one is allowed") }
        var options: [String: String] = [:]
        if let record = txt.first, !record.isEmpty {
            for pair in record.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { throw MongoError(.dns, "Malformed TXT option '\(pair)' for \(host)") }
                let name = ConnectionString.canonicalOptionName(String(parts[0]))
                guard allowedTXTOptions.contains(name) else {
                    throw MongoError(.dns, "TXT record option '\(name)' is not allowed (only authSource, replicaSet and loadBalanced)")
                }
                options[name] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        }
        return Result(hosts: hosts, options: options)
    }

    /// The target must share the SRV host's parent domain (and for short hosts, be a subdomain of it).
    static func isValidTarget(_ target: String, forSRVHost host: String) -> Bool {
        let hostLabels = host.lowercased().split(separator: ".")
        let targetLabels = target.lowercased().split(separator: ".")
        guard hostLabels.count >= 1, targetLabels.count > 1 else { return false }
        if hostLabels.count >= 3 {
            let domain = hostLabels.dropFirst()
            return targetLabels.count > domain.count && Array(targetLabels.suffix(domain.count)) == Array(domain)
        }
        // Hosts with fewer than three labels: the target must be a strict subdomain of the host.
        return targetLabels.count > hostLabels.count && Array(targetLabels.suffix(hostLabels.count)) == Array(hostLabels)
    }
}
