// Haptics.swift — DoomCoder Companion
// Thin wrapper around UIFeedbackGenerator so call sites read as intent, not
// boilerplate. All calls are main-actor and no-ops if haptics are unavailable.

import UIKit

@MainActor
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
