import SwiftUI
import AppIntents
import Observation

// MARK: - DoomCoderFocusFilter
//
// App Intent backing the DoomCoder Focus filter. Users add a "DoomCoder
// Working" filter to any Focus mode (Do Not Disturb, Work, etc.) in System
// Settings → Focus → [mode] → Focus Filters → Add Filter. DoomCoder donates
// this intent when agent state flips, so the system's Focus engine toggles
// the mode automatically.
//
// The filter itself holds no state; its `active` parameter is the signal the
// Focus engine consumes.

struct DoomCoderFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Agent Working"
    static let description = IntentDescription(
        "Activates while any AI coding agent is actively working. Donate this filter from a Focus mode to silence other apps automatically when an agent starts."
    )

    @Parameter(title: "Active") var active: Bool?

    init() { self.active = false }

    init(active: Bool) { self.active = active }

    func perform() async throws -> some IntentResult {
        return .result()
    }

    var displayRepresentation: DisplayRepresentation {
        let a = active ?? false
        return DisplayRepresentation(
            title: a ? "Agent Working" : "Agent Idle",
            subtitle: a ? "Any DoomCoder-tracked agent is active" : "No agents active"
        )
    }
}

// MARK: - FocusFilterManager
//
// Observes AgentStatusManager.isAnyAgentActive and donates DoomCoderFocusFilter
// with the matching `active` flag so any Focus mode the user has wired to our
// filter gets flipped on and off.

@MainActor
@Observable
final class FocusFilterManager {

    // UserDefaults key the SYSTEM pane toggles.
    private static let enabledKey = "dc.focus.filter.enabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private(set) var lastDonationAt: Date?
    private(set) var lastDonationActive: Bool = false
    private(set) var lastError: String?

    /// Called by DoomCoderApp.wireAgentBridge whenever `isAnyAgentActive`
    /// flips. Safe to call on every flip — Focus engine ignores duplicates.
    func reflect(active: Bool) {
        guard isEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await DoomCoderFocusFilter(active: active).donate()
                await MainActor.run {
                    self.lastDonationAt = .now
                    self.lastDonationActive = active
                    self.lastError = nil
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    /// One-shot test: flip to active, wait 1.5s, flip back. Used by the
    /// SYSTEM → Focus row Test button.
    func runTest() async -> String {
        do {
            try await DoomCoderFocusFilter(active: true).donate()
            try? await Task.sleep(for: .seconds(1.5))
            try await DoomCoderFocusFilter(active: false).donate()
            lastDonationAt = .now
            lastError = nil
            return "Focus filter donated active + inactive. If a Focus mode is wired to 'DoomCoder Working', it flipped on and off."
        } catch {
            lastError = error.localizedDescription
            return "Failed: \(error.localizedDescription)"
        }
    }
}
