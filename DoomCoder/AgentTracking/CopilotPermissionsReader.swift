import Foundation

// Reads ~/.copilot/permissions-config.json and tells the Copilot CLI normalizer
// whether a permissionRequest hook event would be auto-approved by Copilot's
// built-in allowlist. When auto-approved, Copilot shows no UI, so DoomCoder
// suppresses the notification to avoid phantom alerts.
//
// nonisolated(unsafe) is intentional: this singleton is only ever accessed
// from AgentTrackingManager (@MainActor), so there are no actual data races.
// Avoiding @MainActor on the class prevents the [String:Any] non-Sendable
// capture issue when calling from a Sendable normalizer struct.
final class CopilotPermissionsReader {
    nonisolated(unsafe) static let shared = CopilotPermissionsReader()

    private var cachedConfig: [String: Any] = [:]
    private var cacheDate: Date = .distantPast
    private let cacheTTL: TimeInterval = 5

    private init() {}

    // MARK: - Public API

    /// Returns true if the given `promptRequest` dict (from the permissionRequest
    /// hook payload) would be auto-approved by Copilot's allowlist for `cwd`.
    /// When true the caller should NOT send a notification.
    func isAutoApproved(promptRequest: [String: Any], cwd: String) -> Bool {
        let approvals = allowedApprovals(for: cwd)
        guard !approvals.isEmpty else { return false }

        let kind = promptRequest["kind"] as? String ?? ""

        switch kind {

        case "commands":
            // Each command identifier in the request must be covered by an
            // approved identifier. Matching is prefix-based:
            //   allowed "git add"  covers reqId "git add" or "git add -A ..."
            //   allowed "rm"       covers reqId "rm" or "rm -rf ..."
            // Comparison is case-sensitive (same as Copilot's own matching).
            let reqIds = promptRequest["commandIdentifiers"] as? [String] ?? []
            guard !reqIds.isEmpty else { return false }
            return reqIds.allSatisfy { reqId in
                approvals.contains { entry in
                    guard (entry["kind"] as? String) == "commands",
                          let allowed = entry["commandIdentifiers"] as? [String]
                    else { return false }
                    return allowed.contains { prefix in
                        // Exact match or "prefix + space" so we don't match
                        // "rm" against "rmdir" etc.
                        reqId == prefix || reqId.hasPrefix(prefix + " ")
                    }
                }
            }

        case "write":
            // A bare {"kind":"write"} entry approves all file writes.
            return approvals.contains { ($0["kind"] as? String) == "write" }

        case "read":
            return approvals.contains { ($0["kind"] as? String) == "read" }

        case "mcp":
            let reqServer = promptRequest["serverName"] as? String ?? ""
            let reqTool   = promptRequest["toolName"]   as? String ?? ""
            return approvals.contains { entry in
                guard (entry["kind"] as? String) == "mcp" else { return false }
                let server = entry["serverName"] as? String ?? ""
                let tool   = entry["toolName"]   as? String ?? ""
                return server == reqServer && tool == reqTool
            }

        case "url":
            // URL approvals live in ~/.copilot/settings.json "allowedUrls".
            // Conservatively always notify for URL requests.
            return false

        default:
            // memory, custom-tool, hook, path, extension-* — no allowlist
            // equivalent; always notify.
            return false
        }
    }

    // MARK: - Config loading

    private func allowedApprovals(for cwd: String) -> [[String: Any]] {
        let config = loadConfig()
        guard let locations = config["locations"] as? [String: Any] else { return [] }

        // Normalise the incoming cwd: resolve symlinks and strip trailing slash
        // so path comparison works regardless of how the hook reports it.
        let resolvedCwd = URL(fileURLWithPath: cwd)
            .resolvingSymlinksInPath().path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty ? cwd : URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path

        // Walk from the most specific (deepest) key toward root so that a
        // project-level rule takes precedence over a parent directory rule.
        let sortedKeys = locations.keys.sorted { $0.count > $1.count }
        for key in sortedKeys {
            let resolvedKey = URL(fileURLWithPath: key)
                .resolvingSymlinksInPath().path
            let dirPath = resolvedKey.hasSuffix("/") ? resolvedKey : resolvedKey + "/"
            if resolvedCwd == resolvedKey || resolvedCwd.hasPrefix(dirPath) {
                let loc = locations[key] as? [String: Any] ?? [:]
                return loc["tool_approvals"] as? [[String: Any]] ?? []
            }
        }
        return []
    }

    private func loadConfig() -> [String: Any] {
        let now = Date()
        if now.timeIntervalSince(cacheDate) < cacheTTL {
            return cachedConfig
        }
        let path = NSHomeDirectory() + "/.copilot/permissions-config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            cacheDate = now
            cachedConfig = [:]
            return [:]
        }
        cacheDate   = now
        cachedConfig = dict
        return dict
    }
}
