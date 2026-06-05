// PendingPairRequestSubscription.swift — DoomCoder Mac
// v5.1: Mac-side subscriber for CSC{pending,origin:ios} records
// on the public database. The iOS app writes these when the
// user taps a Mac in the "Same iCloud" discoverable list. The
// Mac receives an APNs silent push within 1-3s and shows the
// PendingPairRequestBanner.
//
// Why the public DB and not the Mac's private zone: the CSC
// needs to be addressable by the iOS app (which uses the
// default container, not a per-share engine), and the iOS app
// already subscribes to the public DB for DiscoverableMac. We
// piggy-back on the same subscription.

import Foundation
import CloudKit
import OSLog
import DoomCoderCore

@MainActor
final class PendingPairRequestSubscription {
    static let shared = PendingPairRequestSubscription()

    private let logger = Logger(subsystem: "com.doomcoder", category: "csc.public.mac")
    private let container: CKContainer
    private let subscriptionID = "csc-public-pending-v1"
    private let userDefaultsKey = "doomcoder.mac.csc.public.subscriptionInstalled.v1"

    private init(container: CKContainer = CKContainer(identifier: CloudKitConstants.containerIdentifier)) {
        self.container = container
    }

    /// Idempotent. Called from `DoomCoderAppDelegate`.
    func start() async {
        await installSubscriptionIfNeeded()
        await refresh()
    }

    /// Fetches all CSC records on the public DB and posts
    /// .macReceivedPendingCSC for any .pending one. Called on
    /// app launch, on APNs silent push, and on a 30s timer so a
    /// missed push doesn't keep the user waiting.
    func refresh() async {
        let db = container.publicCloudDatabase
        let pred = NSPredicate(value: true)
        let query = CKQuery(
            recordType: CloudKitConstants.RecordType.connectionStateChange,
            predicate: pred
        )
        do {
            let (results, _) = try await db.records(
                matching: query,
                inZoneWith: nil
            )
            for (_, result) in results {
                if case .success(let ckRecord) = result,
                   let csc = ConnectionStateChangeRecord(ckRecord) {
                    NotificationCenter.default.post(
                        name: .macReceivedPendingCSC,
                        object: nil,
                        userInfo: ["csc": csc]
                    )
                }
            }
        } catch {
            logger.warning("csc.public.mac: refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func installSubscriptionIfNeeded() async {
        if UserDefaults.standard.bool(forKey: userDefaultsKey) { return }
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.connectionStateChange,
            predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do {
            try await container.publicCloudDatabase.save(sub)
            UserDefaults.standard.set(true, forKey: userDefaultsKey)
            logger.notice("csc.public.mac: installed subscription")
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            UserDefaults.standard.set(true, forKey: userDefaultsKey)
            logger.notice("csc.public.mac: subscription already exists")
        } catch {
            logger.warning("csc.public.mac: install failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
