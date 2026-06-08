import SwiftUI
import AppKit

// MARK: - WhatsNewHost
//
// Single dispatch point for the "What's New" sheet. The four legacy
// `WhatsNewSheet*` structs (in `WhatsNewSheet.swift`) stay where they are;
// this view picks the highest-version unseen sheet and shows it.
//
// When the user dismisses the host, the next-lowest unseen sheet is
// shown (if any). Each sheet's `onDismiss` callback closes the host
// window, which removes the SwiftUI scene; the AppDelegate re-opens it
// on `applicationDidFinishLaunching` (or we just don't, since the
// version has been marked as seen).
//
// This view is hosted by a SwiftUI `Window(id: "whatsNew")` scene in
// `DoomCodeApp.swift`. The window is `.floating` (so it appears above
// other apps) and uses default title-bar close behaviour (so the user
// can dismiss with the traffic-light X).

public struct WhatsNewHost: View {
    @Environment(\.dismiss) private var dismiss
    @State private var version: WhatsNewVersion? = WhatsNewVersion.highestUnseen()

    public init() {}

    public var body: some View {
        Group {
            if let v = version {
                sheet(for: v)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("You're all caught up.")
                        .font(.title3.weight(.semibold))
                    Text("Doom Coder has no new features to announce right now.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                .frame(width: 460, height: 280)
            }
        }
        .frame(width: 520, height: 480)
    }

    @ViewBuilder
    private func sheet(for v: WhatsNewVersion) -> some View {
        switch v {
        case .v230:
            WhatsNewSheet230 { markSeenAndDismiss(v) }
        case .v220:
            WhatsNewSheet220 { markSeenAndDismiss(v) }
        case .v2:
            WhatsNewSheetV2(onDismiss: { markSeenAndDismiss(v) })
        case .v190:
            WhatsNewSheet(onDismiss: { markSeenAndDismiss(v) })
        }
    }

    private func markSeenAndDismiss(_ v: WhatsNewVersion) {
        UserDefaults.standard.set(true, forKey: v.defaultsKey)
        // Advance to the next unseen version (or nil if all seen).
        if let next = WhatsNewVersion.allCases.sorted().last(where: { $0 != v && !UserDefaults.standard.bool(forKey: $0.defaultsKey) }) {
            version = next
        } else {
            dismiss()
        }
    }
}

// MARK: - WhatsNewVersion
//
// Ordered enum of every "What's New" sheet we ship. `Comparable` so
// `last(where:)` picks the highest. `defaultsKey` is the UserDefaults
// flag the AppDelegate used to gate the legacy sheet.
//
// When you add a new sheet:
//   1. Add a new case here with a unique `defaultsKey`.
//   2. Add a new `WhatsNewSheet<Version>` struct in `WhatsNewSheet.swift`.
//   3. Add a new case to `WhatsNewHost.sheet(for:)`.
//
// Migration: existing users have the old `doomcoder.whatsnew.v2_3_0.seen`
// etc. flags set. The host sees no unseen versions and shows the
// "caught up" view (or nothing at all if the window never opens).

public enum WhatsNewVersion: String, CaseIterable, Comparable {
    case v190 = "v190"
    case v2   = "v2"
    case v220 = "v220"
    case v230 = "v230"

    public var defaultsKey: String {
        switch self {
        case .v190: return "whats_new_v1_9_0_shown"
        case .v2:   return "whats_new_v2_0_0_shown"
        case .v220: return "whats_new_v2_2_0_shown"
        case .v230: return "doomcoder.whatsnew.v2_3_0.seen"
        }
    }

    /// Returns the highest-version unseen sheet, or nil if all are seen.
    public static func highestUnseen() -> WhatsNewVersion? {
        allCases.sorted().last { !UserDefaults.standard.bool(forKey: $0.defaultsKey) }
    }

    public static func < (lhs: WhatsNewVersion, rhs: WhatsNewVersion) -> Bool {
        // Order matters: later cases (newer) are "greater than" earlier ones.
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
