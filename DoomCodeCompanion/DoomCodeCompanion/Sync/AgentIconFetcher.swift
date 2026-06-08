// AgentIconFetcher.swift — bundle → App Group seeding.
// On first launch the NSE (which runs in its own process) has no agent
// PNGs available. The CloudKit AgentIcon sync from the Mac will eventually
// populate the App Group cache, but until then the NSE falls back to no
// icon attachment. To avoid that gap, we copy each bundled agent PNG into
// the App Group cache on every launch — cheap (≈6 small PNGs) and makes
// the NSE work offline / before the first CloudKit sync.

import Foundation
import UIKit
import DoomCodeCore

enum AgentIconFetcher {
    /// Seed bundled agent PNGs into the shared App Group cache so the NSE
    /// can attach them to notifications before CloudKit has had a chance
    /// to push the Mac-rendered icons across.
    static func prefetchIfNeeded() {
        for agent in TrackedAgent.allCases {
            guard let image = UIImage(named: agent.bundledAssetName),
                  let data = image.pngData() else { continue }
            // Persist under both the bundled-asset-name and the iconSlug
            // (some legacy code reads slug-keyed paths). The bundledAssetName
            // already starts with "agent-", so strip the prefix for the
            // slug form expected by AppGroupCache.
            let slug = agent.iconSlug
            if AppGroupCache.iconURL(slug: slug) == nil
                || !FileManager.default.fileExists(atPath:
                    AppGroupCache.iconURL(slug: slug)?.path ?? "") {
                AppGroupCache.writeIcon(slug: slug, data: data)
            }
        }
    }
}
