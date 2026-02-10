// AgentIconFetcher.swift — CDN fetch removed in v4.0.
// Icons are now sourced exclusively from:
//   1. Bundle asset catalog (ships with the app, cold-launch safe).
//   2. App Group icon cache populated by CloudKit AgentIcon records from the Mac.
// The CDN (lobehub/jsdelivr) fetch was a workaround for the initial release
// and is no longer needed now that the Mac publishes AgentIcon records on
// install, which land in the App Group within one sync cycle.

import Foundation
import DoomCoderCore

enum AgentIconFetcher {
    /// No-op. CDN prefetch removed; bundle assets + CloudKit AgentIcon sync
    /// are the canonical icon sources.
    static func prefetchIfNeeded() {}
}
