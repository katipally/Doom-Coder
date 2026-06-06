// ConnectionStateChanges.swift — DoomCoder Companion
//
// v7: NEUTRALIZED. Connection state is no longer tracked by hand-rolled
// ConnectionStateChange records + monotonic counters. It is DERIVED on each
// side from the presence of the peer's `DeviceRecord` in the shared zone and
// the freshness of its `lastSeen` heartbeat (see `DerivedDeviceState` in
// DoomCoderCore). The iPhone:
//   • same-iCloud  → starts writing its own DeviceRecord into the Mac's
//     private zone (promptless) the moment a Connection exists.
//   • different-iCloud → calls `container.accept(metadata)` then its shared
//     engine writes its DeviceRecord into the Mac's shared zone.
// Disconnect = delete the iPhone's own DeviceRecord (+ leave the share); the
// Mac derives the disconnect from the vanished record / revoked zone.
//
// This file is intentionally left as a no-op placeholder so the Xcode project
// membership stays unchanged. The old CSC publish/ingest writer, the
// CSCPendingCache, and the prompt-driven pairing handshake have been removed.

import Foundation
