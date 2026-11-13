import Foundation

/// Picks the server to use from a seed list (no background monitoring; re-run after failures).
struct ServerSelector: Sendable {
    struct Probe: Sendable {
        let address: ServerAddress
        let hello: HelloResponse
        let roundTrip: Duration
    }

    let seeds: [ServerAddress]
    let direct: Bool
    let replicaSet: String?
    let readPreference: ReadPreferenceMode
    let probe: @Sendable (ServerAddress) async throws -> (HelloResponse, Duration)

    func select() async throws -> Probe {
        guard let first = seeds.first else {
            throw MongoError(.serverSelection, "No hosts to connect to")
        }
        if direct {
            let (hello, rtt) = try await probe(first)
            return Probe(address: first, hello: hello, roundTrip: rtt)
        }

        var failures: [String] = []
        var probes = await probeAll(seeds, failures: &failures)
        probes = probes.filter { replicaSet == nil || $0.hello.setName == replicaSet }

        if let mongos = probes.filter({ $0.hello.isMongos }).min(by: { $0.roundTrip < $1.roundTrip }) {
            return mongos
        }

        // Discover replica-set members the seeds told us about.
        let known = Set(probes.map(\.address))
        let advertised = Set(probes.flatMap(\.hello.memberAddresses).compactMap { try? ServerAddress(parsing: $0) })
        let unprobed = Array(advertised.subtracting(known))
        if !unprobed.isEmpty, needsMoreMembers(probes) {
            let extra = await probeAll(unprobed, failures: &failures)
            probes += extra.filter { replicaSet == nil || $0.hello.setName == replicaSet }
        }

        if let chosen = choose(from: probes) { return chosen }

        let setDescription = replicaSet.map { " in replica set '\($0)'" } ?? ""
        let reason = probes.isEmpty
            ? "Could not reach any server\(setDescription): " + failures.joined(separator: "; ")
            : "No server\(setDescription) matches read preference '\(readPreference.rawValue)'"
        throw MongoError(.serverSelection, reason)
    }

    private func needsMoreMembers(_ probes: [Probe]) -> Bool {
        switch readPreference {
        case .primary, .primaryPreferred: !probes.contains { $0.hello.serverType == .rsPrimary }
        case .secondary, .secondaryPreferred: !probes.contains { $0.hello.serverType == .rsSecondary }
        case .nearest: probes.isEmpty
        }
    }

    private func choose(from probes: [Probe]) -> Probe? {
        let fastest: ([Probe]) -> Probe? = { $0.min(by: { $0.roundTrip < $1.roundTrip }) }
        let primaries = probes.filter { $0.hello.serverType == .rsPrimary }
        let secondaries = probes.filter { $0.hello.serverType == .rsSecondary }
        let standalones = probes.filter { $0.hello.serverType == .standalone }
        switch readPreference {
        case .primary: return fastest(primaries) ?? fastest(standalones)
        case .primaryPreferred: return fastest(primaries) ?? fastest(secondaries) ?? fastest(standalones)
        case .secondary: return fastest(secondaries) ?? fastest(standalones)
        case .secondaryPreferred: return fastest(secondaries) ?? fastest(primaries) ?? fastest(standalones)
        case .nearest: return fastest(primaries + secondaries + standalones)
        }
    }

    private func probeAll(_ addresses: [ServerAddress], failures: inout [String]) async -> [Probe] {
        let probe = self.probe
        let results = await withTaskGroup(of: (ServerAddress, Result<(HelloResponse, Duration), any Error>).self) { group in
            for address in addresses {
                group.addTask {
                    do {
                        return (address, .success(try await probe(address)))
                    } catch {
                        return (address, .failure(error))
                    }
                }
            }
            var collected: [(ServerAddress, Result<(HelloResponse, Duration), any Error>)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        var probes: [Probe] = []
        for (address, result) in results {
            switch result {
            case let .success((hello, rtt)): probes.append(Probe(address: address, hello: hello, roundTrip: rtt))
            case let .failure(error): failures.append("\(address): \((error as? MongoError)?.message ?? error.localizedDescription)")
            }
        }
        return probes
    }
}
