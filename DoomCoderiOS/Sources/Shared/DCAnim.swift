import SwiftUI

// Centralized animation tokens for DoomCoder iOS — mirrors the Mac DCAnim enum.
//
// .snap     — tab switches, small selection changes, opacity flips
// .smooth   — standard panel/detail transitions, accordion toggles
// .bouncy   — entering/exiting prominent views, first-run reveals
// .fade     — pure opacity crossfades (no geometry)
// .micro    — tight ≤150ms state updates (counters, subtle indicators)
enum DCAnim {
    static let snap: Animation = .snappy(duration: 0.22, extraBounce: 0.0)
    static let smooth: Animation = .smooth(duration: 0.32, extraBounce: 0.0)
    static let bouncy: Animation = .bouncy(duration: 0.4, extraBounce: 0.12)
    static let fade: Animation = .easeInOut(duration: 0.18)
    static let micro: Animation = .easeOut(duration: 0.15)
    static let accordion: Animation = .interpolatingSpring(
        mass: 1.0, stiffness: 380, damping: 38, initialVelocity: 0
    )
}
