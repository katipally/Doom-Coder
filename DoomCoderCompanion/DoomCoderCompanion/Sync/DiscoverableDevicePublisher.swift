// DiscoverableDevicePublisher.swift — DoomCoder Companion
//
// v6: publishes this iPhone's presence to the public CloudKit database so a
// same-iCloud Mac can discover it in the Add-Device "Same iCloud" picker and
// initiate a pairing request. The Mac is the initiator of every pairing in v6;
// the iPhone is the acceptor.
//
// Record lives in the public DB default zone, keyed by the stable iosDeviceId,
// and carries `publishedBy` (the iPhone's userRecordID) so the Mac can confirm
// same-iCloud before requesting.

import Foundation
import CloudKit
import UIKit
import OSLog
import DoomCoderCore

@MainActor
final class DiscoverableDevicePublisher {

    static let shared = DiscoverableDevicePublisher()

    private let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    private var db: CKDatabase { container.publicCloudDatabase }
    private let logger = Logger(subsystem: "com.doomcoder", category: "discoverable.device")
    private var lastPublishedAt: Date = .distantPast
    private var inFlight = false

    private init() {}

    func start() {
        publishNow(force: true)
        // Re-publish on account change so a sign-out/switch updates presence.
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                IosDeviceId.invalidateICloudUserRecordName()
                DiscoverableDevicePublisher.shared.publishNow(force: true)
            }
        }
    }

    /// Publish presence. Debounced to once per 30s unless `force`.
    func publishNow(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPublishedAt) > 30 else { return }
        guard !inFlight else { return }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            await publish()
        }
    }

    private func publish() async {
        guard let userRecordName = await IosDeviceId.iCloudUserRecordName() else { return }
        // Identity (name/email) is best-effort and surfaced via the
        // non-deprecated CKShare.Participant.userIdentity during pairing; the
        // presence record carries the stable device name + userRecordID.
        let rec = DiscoverableDeviceRecord(
            iosDeviceId: IosDeviceId.current,
            name: IosDeviceId.displayName,
            model: IosDeviceId.model,
            systemVersion: IosDeviceId.systemName,
            lastSeen: Date(),
            publishedBy: userRecordName
        )
        let op = CKModifyRecordsOperation(recordsToSave: [rec.toCKRecord()], recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        op.qualityOfService = .utility
        op.modifyRecordsResultBlock = { [weak self] result in
            if case .failure(let err) = result {
                Task { @MainActor in
                    self?.logger.error("publish failed: \(err.localizedDescription, privacy: .public)")
                }
            }
        }
        db.add(op)
        lastPublishedAt = Date()
    }
}
