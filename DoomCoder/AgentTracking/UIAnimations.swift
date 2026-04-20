import SwiftUI

// Centralized animation tokens for DoomCoder.
//
// Why: macOS 26 / SwiftUI ships curated curves (`.snappy`, `.smooth`, `.bouncy`)
// that feel native. Instead of scattered `.spring(duration: 0.3, bounce: 0.12)`
// calls with drifting parameters, every view uses one of these tokens so the
// whole app moves with a consistent rhythm.
//
// Guidance:
//   .snap     — tab switches, small selection changes, opacity flips
//   .smooth   — standard panel/detail transitions, accordion toggles
//   .bouncy   — entering/exiting prominent views, first-run reveals
//   .fade     — pure opacity crossfades (no geometry)
//   .micro    — tight ≤150ms state updates (counters, subtle indicators)
//
// All tokens resolve to native macOS 26 presets so reduce-motion and
// system-wide animation scaling respect Accessibility settings automatically.
enum DCAnim {
    /// Fast, lightly-damped spring for sidebar/tab selection and toggles.
    static let snap: Animation = .snappy(duration: 0.22, extraBounce: 0.0)

    /// Standard content transition — detail pane swaps, accordions, list insertions.
    static let smooth: Animation = .smooth(duration: 0.32, extraBounce: 0.0)

    /// Prominent entrance for sheets, first-mount reveals, and celebratory state.
    static let bouncy: Animation = .bouncy(duration: 0.4, extraBounce: 0.12)

    /// Pure cross-fade — use when geometry must not move (text swaps, icons).
    static let fade: Animation = .easeInOut(duration: 0.18)

    /// Tight state update — counters, status text, small number changes.
    static let micro: Animation = .easeOut(duration: 0.15)
}
