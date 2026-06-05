// DiscoverableMacSubscription.swift — DoomCoder Companion
// v5.1: iOS-side subscription to the public-DB `DiscoverableMac`
// records. Mac is the source of truth; iPhones are passive
// subscribers. The subscription uses CKQuerySubscription with
// shouldSendContentAvailable=true so an APNs silent push wakes
// the iOS app within 1-3s of any Mac-side republish.
//
// Discovery latency: 1-3s via APNs silent push, plus the time
// for the Mac to actually republish (5-min heartbeat or on event).
// In the worst case the iOS user sees a list that is up to 5 min
// stale — acceptable for the "I want to pair my Mac" UX.
//
// Why not a CKSyncEngine on the public DB?
//   • The iOS app reads but never writes DiscoverableMac records.
//   • CKSyncEngine is overkill for a one-type, public-DB read.
//   • We can use a simple CKQuerySubscription + a manual
//     `CKQueryOperation` fetch on receipt. This is exactly the
//     pattern Apple recommends in the CKQuerySubscription docs.

import Foundation
import CloudKit
import OSLog
import DoomCoderCore

@MainActor
final class DiscoverableMacSubscription: ObservableObject {
    static let shared = DiscoverableMacSubscription()

    private let logger = Logger(subsystem: "com.doomcoder", category: "discoverable.ios")
    private let container: CKContainer
    private let subscriptionID = "discoverable-mac-v1"
    private let cscSubscriptionID = "csc-public-v1"
    private let userDefaultsKey = "doomcoder.ios.discoverable.subscriptionInstalled.v1"
    private let cscUserDefaultsKey = "doomcoder.ios.csc.public.subscriptionInstalled.v1"
    private var queryChangeToken: CKQuerySubscription.Options?

    /// The most-recent list of discovered Macs, sorted by
    /// `lastSeen` descending. Observed by the iOS Add Mac sheet's
    /// "Same iCloud" tab.
    @Published private(set) var discovered: [DiscoverableMacRecord] = []

    /// True until the first fetch completes. Used by the UI to
    /// render a spinner on first paint.
    @Published private(set) var isLoading: Bool = false

    /// Last error from a fetch / install attempt. The UI shows
    /// an inline error banner when non-nil.
    @Published private(set) var lastError: String?

    /// The iOS app's own CloudKit user record name. Captured on
    /// `start()` and used by the Same iCloud tab to classify each
    /// row as "Same iCloud" or "Different iCloud" without making
    /// any CloudKit calls.
    @Published private(set) var localUserRecordName: String?

    private init(container: CKContainer = CKContainer(identifier: CloudKitConstants.containerIdentifier)) {
        self.container = container
    }

    /// Idempotent. Called from `CompanionSyncEngine.start()`.
    /// Also called from the Same iCloud tab's onAppear to
    /// re-install the subscription if it was lost (e.g. after
    /// a CKAccountChanged rotation).
    func start() async {
        // Capture our own user record name. If the iOS user isn't
        // signed in to iCloud, this is nil — in that case the
        // Same iCloud tab shows a "Sign in to iCloud" empty state.
        do {
            let id = try await container.userRecordID()
            localUserRecordName = id.recordName
        } catch {
            logger.warning("discoverable.ios: userRecordID failed: \(error.localizedDescription, privacy: .public)")
            localUserRecordName = nil
        }
        await installDiscoverableMacSubscription()
        await installPublicCSCSubscription()
        await refresh()
    }

    /// Re-fetches the latest list of discovered Macs. Called
    /// on subscription install, on APNs silent push receipt,
    /// on pull-to-refresh, and on Same iCloud tab onAppear.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let db = container.publicCloudDatabase
        let pred = NSPredicate(value: true)
        let query = CKQuery(recordType: CloudKitConstants.RecordType.discoverableMac, predicate: pred)
        do {
            let (matchResults, _) = try await db.records(
                matching: query,
                inZoneWith: nil
            )
            var records: [DiscoverableMacRecord] = []
            for (_, result) in matchResults {
                if case .success(let ckRecord) = result,
                   let rec = DiscoverableMacRecord(ckRecord) {
                    records.append(rec)
                }
            }
            records.sort { $0.lastSeen > $1.lastSeen }
            // Stale records (last seen > 30d) are hidden — Mac
            // re-publishes every 5 min while active so a row
            // older than 30d is genuinely abandoned.
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            self.discovered = records.filter { $0.lastSeen >= cutoff }
            self.lastError = nil
        } catch {
            logger.warning("discoverable.ios: refresh failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = "Couldn't load discoverable Macs. Pull to refresh."
        }
    }

    /// v5.1: fetches the latest CSCs on the public DB so the iOS
    /// app sees the Mac's response to a CSC{pending,origin:ios}
    /// request. Called after the iOS user taps a Mac in the
    /// discoverable list. Idempotent.
    func fetchPublicCSCs() async {
        let db = container.publicCloudDatabase
        let pred = NSPredicate(value: true)
        let query = CKQuery(
            recordType: CloudKitConstants.RecordType.connectionStateChange,
            predicate: pred
        )
        do {
            let (matchResults, _) = try await db.records(
                matching: query,
                inZoneWith: nil
            )
            for (_, result) in matchResults {
                if case .success(let ckRecord) = result {
                    ConnectionStateChanges.shared.ingest(ckRecord)
                }
            }
        } catch {
            logger.warning("discoverable.ios: CSC fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Subscriptions

    private func installDiscoverableMacSubscription() async {
        if UserDefaults.standard.bool(forKey: userDefaultsKey) { return }
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.discoverableMac,
            predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        await savePublicSubscription(sub, flagKey: userDefaultsKey, name: "discoverable-mac")
    }

    /// v5.1: also install a subscription for CSC records on the
    /// public DB so the iOS app receives an APNs silent push
    /// when the Mac publishes CSC{accepted} / CSC{denied} in
    /// response to the iOS app's CSC{pending} request. The
    /// receiving path is the same `ConnectionStateChanges.ingest`
    /// used for private-DB CSCs.
    private func installPublicCSCSubscription() async {
        if UserDefaults.standard.bool(forKey: cscUserDefaultsKey) { return }
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.connectionStateChange,
            predicate: NSPredicate(value: true),
            subscriptionID: cscSubscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        await savePublicSubscription(sub, flagKey: cscUserDefaultsKey, name: "csc-public")
    }

    private func savePublicSubscription(
        _ sub: CKQuerySubscription,
        flagKey: String,
        name: String
    ) async {
        do {
            try await container.publicCloudDatabase.save(sub)
            UserDefaults.standard.set(true, forKey: flagKey)
            logger.notice("discoverable.ios: installed \(name, privacy: .public) subscription")
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            UserDefaults.standard.set(true, forKey: flagKey)
            logger.notice("discoverable.ios: \(name, privacy: .public) subscription already exists")
        } catch {
            logger.warning("discoverable.ios: \(name, privacy: .public) install failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Same-iCloud classification helper

extension DiscoverableMacSubscription {
    /// True if the discovered Mac was published from the same
    /// iCloud account as the iOS app. Determined client-side by
    /// comparing `publishedBy` (a hint the Mac wrote into the
    /// record) against `localUserRecordName` (the iOS app's own
    /// user record name). This is a HINT only — the authoritative
    /// same-iCloud check happens at probe time via
    /// `CKRecord.creatorUserRecordID` on the CSC{pending,origin:ios}
    /// record.
    func isSameICloudAccount(_ record: DiscoverableMacRecord) -> Bool {
        guard let local = localUserRecordName, !local.isEmpty else { return false }
        return record.publishedBy == local
    }
}
