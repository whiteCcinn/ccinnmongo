import CcinnMongoKit
import Foundation

/// A profile chosen for a call, with its effective access level (after `--read-only`).
public struct SelectedProfile: Sendable, Equatable {
    public let profile: ConnectionProfile
    public let access: MCPAccessLevel
}

/// Implements the connection selection rules of the MCP server.
public enum MCPProfileSelector {
    static let enableHint = "Enable it in CcinnMongo: edit the connection → AI Access, or Settings → MCP."

    /// The profile's name, or its host list when unnamed. Unlike `displayName` this never falls back to
    /// the raw connection string (which could carry an inline password in a hand-edited profile file).
    public static func safeName(_ profile: ConnectionProfile) -> String {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? MongoToolProvider.hosts(of: profile) : name
    }

    public static func effectiveAccess(_ profile: ConnectionProfile, cap: MCPAccessLevel) -> MCPAccessLevel {
        profile.mcpAccess.capped(at: cap)
    }

    public static func enabledProfiles(_ profiles: [ConnectionProfile], cap: MCPAccessLevel) -> [ConnectionProfile] {
        profiles.filter { effectiveAccess($0, cap: cap).allowsReads }
    }

    /// - `requested`: the tool's `connection` argument; `defaultProfile`: `--profile`.
    public static func select(requested: String?, defaultProfile: String?, profiles: [ConnectionProfile],
                              cap: MCPAccessLevel) -> Result<SelectedProfile, MCPToolFailure> {
        let enabled = enabledProfiles(profiles, cap: cap)
        let names = enabled.map(safeName).joined(separator: ", ")
        let reference = [requested, defaultProfile]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let reference else {
            switch enabled.count {
            case 0:
                return .failure(MCPToolFailure("No connections are enabled for AI access. \(enableHint)"))
            case 1:
                return .success(SelectedProfile(profile: enabled[0], access: effectiveAccess(enabled[0], cap: cap)))
            default:
                return .failure(MCPToolFailure("Several connections are enabled; pass \"connection\" with one of: \(names)."))
            }
        }

        let matches = match(reference, in: profiles)
        guard let profile = matches.first else {
            let available = enabled.isEmpty ? "No connections are enabled for AI access." : "Enabled connections: \(names)."
            return .failure(MCPToolFailure("No connection named \"\(reference.clipped(100))\". \(available)"))
        }
        guard matches.count == 1 else {
            let ids = matches.map { $0.id.uuidString }.joined(separator: ", ")
            return .failure(MCPToolFailure("Several connections are named \"\(reference.clipped(100))\"; pass one of these ids as \"connection\": \(ids)."))
        }
        let access = effectiveAccess(profile, cap: cap)
        guard access.allowsReads else {
            return .failure(MCPToolFailure("Connection \"\(safeName(profile))\" is not enabled for AI access. \(enableHint)"))
        }
        return .success(SelectedProfile(profile: profile, access: access))
    }

    /// Id first, then exact display name, then case-insensitive display name.
    static func match(_ reference: String, in profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        if let id = UUID(uuidString: reference), let profile = profiles.first(where: { $0.id == id }) {
            return [profile]
        }
        let exact = profiles.filter { safeName($0) == reference }
        if !exact.isEmpty { return exact }
        return profiles.filter { safeName($0).caseInsensitiveCompare(reference) == .orderedSame }
    }
}
