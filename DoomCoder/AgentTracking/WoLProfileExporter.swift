// WoLProfileExporter.swift — DoomCoder
//
// DEPRECATED in v3.0. Wake-on-LAN was removed when iOS companion adopted
// CloudKit-only transport. CloudKit silent pushes wake a sleeping Mac on
// their own (APNs over Wi-Fi or cellular), so the magic-packet path is no
// longer needed. The file is retained as a no-op stub so the Xcode
// project keeps compiling without a `.pbxproj` edit.

import Foundation

@MainActor
enum WoLProfileExporter {
    static func publish() {
        // intentionally empty
    }
}
