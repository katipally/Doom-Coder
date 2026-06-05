// PendingPairRequestQueue.swift — DoomCoder Mac
// v5.1: in-memory model that listens for CSC{pending,origin:ios}
// records arriving via the public-DB subscription and exposes
// them to the UI (the PendingPairRequestBanner). The Mac user
// clicks Allow / Deny in a sheet; on Allow we create a real
// Connection and publish CSC{accepted,origin:mac}; on Deny we
// publish CSC{denied,origin:mac}.
//
// Dedupe: each CSC carries a stateChangeCounter in its record
// name. The queue dedupes by (macId, iosDeviceId, counter) so
// a silent-push replay doesn't re-show an already-acted-on
// request.

import Foundation
import CloudKit
import Combine
import DoomCoderCore

@MainActor
final class PendingPairRequestQueue: ObservableObject {
    static let shared = PendingPairRequestQueue()

    struct Request: Equatable, Identifiable {
        let macId: String
        let iosDeviceId: String
        let iosUserRecordID: String?
        let timestamp: Date
        var id: String { "\(macId)-\(iosDeviceId)" }
    }

    @Published private(set) var requests: [Request] = []

    private init() {
        // v5.1: the iOS CSC arrives on the PUBLIC database (we
        // wrote a CSC{pending,origin:ios} from the Same iCloud
        // tab). The Mac fetches it via its own public-DB
        // CKQuerySubscription (or via a manual fetch on push
        // notification). On receive, post this notification
        // so the UI can pick it up.
        NotificationCenter.default.addObserver(
            forName: .macReceivedPendingCSC,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let csc = note.userInfo?["csc"] as? ConnectionStateChangeRecord else { return }
            MainActor.assumeIsolated {
                self?.enqueue(csc)
            }
        }
    }

    func enqueue(_ csc: ConnectionStateChangeRecord) {
        // Only iOS-originated .pending CSCs are queue candidates.
        guard csc.origin == ConnectionStateChangeRecord.Origin.ios.rawValue,
              csc.state == ConnectionStateChangeRecord.State.pending.rawValue
        else { return }
        // Dedupe by (macId, iosDeviceId). A user who taps the same
        // Mac twice in quick succession will only see one banner.
        if requests.contains(where: {
            $0.macId == csc.macId && $0.iosDeviceId == csc.iosDeviceId
        }) { return }
        let req = Request(
            macId: csc.macId,
            iosDeviceId: csc.iosDeviceId,
            iosUserRecordID: csc.iosUserRecordID,
            timestamp: csc.timestamp
        )
        requests.append(req)
    }

    func remove(_ request: Request) {
        requests.removeAll { $0.id == request.id }
    }
}

extension Notification.Name {
    /// Posted by the Mac's public-DB CSC subscription handler
    /// when a CSC{pending,origin:ios} arrives. Carries the
    /// `csc` (ConnectionStateChangeRecord) in `userInfo`.
    static let macReceivedPendingCSC = Notification.Name("com.doomcoder.mac.receivedPendingCSC")
}
