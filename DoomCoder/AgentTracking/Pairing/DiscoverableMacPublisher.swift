// DiscoverableMacPublisher.swift — DoomCoder Mac
// v5.1: publishes a `DiscoverableMacRecord` to the public iCloud
// database so the iOS companion can render a "discoverable Macs on
// this iCloud account" list in the Add Mac sheet's "Same iCloud"
// tab. The Mac is the source of truth; iPhones are passive
// subscribers.
//
// Lifecycle:
//   • Republish on app launch
//   • Republish on foreground (NSApplication.didBecomeActiveNotification)
//   • Republish on sleep/wake so the iOS list reflects Mac availability
//   • Republish on a 5-minute heartbeat while the app is active
//   • Republish on hostname change (Host.current().localizedName)
//   • Unpublish on app uninstall (CKAccountChanged) so the public
//     DB doesn't accumulate zombie rows
//
// Why the public DB and not a CKShare:
//   • CKShare requires the user to commit (system share sheet).
//     We want a soft "browse" surface so the user can decide.
//   • Apple deprecated CKDiscoverUserIdentitiesOperation in
//     iOS 17 / macOS 14. The non-deprecated way to verify
//     "same iCloud" is to compare CKRecord.creatorUserRecordID
//     on a record the user explicitly writes — which is what
//     the iOS probe does (CSC{pending,origin:ios}).
//
// Why no engine:
//   • CKSyncEngine is overkill for a singleton that re-publishes
//     on events. We use CKModifyRecordsOperation directly with
//     savePolicy = .changedKeys and a server-record cache so
//     the recordChangeTag is preserved.

import Foundation
import CloudKit
import OSLog
import AppKit
import DoomCoderCore

@MainActor
final class DiscoverableMacPublisher {
    static let shared = DiscoverableMacPublisher()

    private let logger = Logger(subsystem: "com.doomcoder", category: "discoverable.mac")
    private let container: CKContainer
    /// Per-record server-record cache so re-publishes preserve
    /// recordChangeTag and avoid CKError 14/2004.
    private var serverRecordCache: [String: CKRecord] = [:]
    private var isStarted = false
    private var republishTimer: Timer?
    private var foregroundObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?

    private init(container: CKContainer = CKContainer(identifier: CloudKitConstants.containerIdentifier)) {
        self.container = container
    }

    /// Starts the publisher. Idempotent. Called from
    /// `DoomCoderAppDelegate.applicationDidFinishLaunching` after
    /// the CloudKitPusher is ready.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        logger.notice("discoverable.mac: starting")

        // Initial publish.
        Task { await republish() }

        // 5-min heartbeat.
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.republish()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        republishTimer = timer

        // Foreground / sleep / wake.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.republish() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.republish() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.republish() }
        }

        // Account change → unpublish so the public DB doesn't
        // accumulate stale rows from a user who signed out of
        // iCloud or switched Apple IDs.
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.unpublish()
                // The new account will trigger start() again from
                // CloudKitPusher's CKAccountChanged handler.
            }
        }
    }

    /// Stops the publisher. Called on app termination.
    func stop() {
        isStarted = false
        republishTimer?.invalidate()
        republishTimer = nil
        if let f = foregroundObserver { NotificationCenter.default.removeObserver(f) }
        if let s = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(s) }
        if let w = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(w) }
        if let a = accountObserver { NotificationCenter.default.removeObserver(a) }
    }

    /// Builds the current record from the Mac's identity and
    /// writes it to the public DB. Idempotent: re-publishing
    /// updates the existing row in place because the record
    /// name is stable (`DiscoverableMac-<macId>`).
    public func republish() async {
        // Skip if not signed in to iCloud. Without an iCloud
        // account we can't write to the public DB.
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                logger.debug("discoverable.mac: skip republish — iCloud not available (\(String(describing: status), privacy: .public))")
                return
            }
        } catch {
            logger.warning("discoverable.mac: accountStatus failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let macId = CloudKitPusher.shared.macId
        let macUserRecordName: String
        do {
            macUserRecordName = try await container.userRecordID().recordName
        } catch {
            logger.warning("discoverable.mac: userRecordID failed: \(error.localizedDescription, privacy: .public))")
            return
        }

        let model = MacModelInfo.currentModelIdentifier()
        let rec = DiscoverableMacRecord(
            macId: macId,
            name: Host.current().localizedName ?? "Mac",
            model: model,
            systemVersion: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            lastSeen: Date(),
            publishedBy: macUserRecordName
        )
        let ck = rec.toCKRecord()
        // Preserve recordChangeTag if we have a cached server copy.
        if let cached = serverRecordCache[ck.recordID.recordName] {
            for key in ck.allKeys() { cached[key] = ck[key] }
        }
        let op = CKModifyRecordsOperation(recordsToSave: [ck], recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        op.qualityOfService = .utility
        op.perRecordSaveBlock = { [weak self] _, result in
            if case .success(let saved) = result {
                Task { @MainActor [weak self] in
                    self?.serverRecordCache[saved.recordID.recordName] = saved
                }
            }
        }
        op.modifyRecordsResultBlock = { [weak self] result in
            if case .failure(let err) = result {
                Task { @MainActor [weak self] in
                    self?.logger.warning("discoverable.mac: republish failed: \(err.localizedDescription, privacy: .public)")
                }
            }
        }
        container.publicCloudDatabase.add(op)
    }

    /// Removes the current Mac from the public DB. Called on
    /// `CKAccountChanged` so a user who signs out doesn't leave
    /// a zombie row. Idempotent.
    public func unpublish() async {
        let macId = CloudKitPusher.shared.macId
        let recordID = CKRecord.ID(recordName: "DiscoverableMac-\(macId)")
        let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [recordID])
        op.savePolicy = .allKeys
        op.qualityOfService = .utility
        op.modifyRecordsResultBlock = { [weak self] result in
            if case .failure(let err) = result {
                Task { @MainActor [weak self] in
                    // .unknownItem means the row was already gone — fine.
                    let nsErr = err as NSError
                    if nsErr.domain == CKErrorDomain && nsErr.code == CKError.unknownItem.rawValue {
                        return
                    }
                    self?.logger.warning("discoverable.mac: unpublish failed: \(err.localizedDescription, privacy: .public)")
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.serverRecordCache.removeValue(forKey: recordID.recordName)
                }
            }
        }
        container.publicCloudDatabase.add(op)
    }
}

// MARK: - Mac model identifier

/// Lightweight wrapper around `sysctl(HW_MODEL)` to get the
/// Mac's model identifier (e.g. "Mac15,3"). Used for the
/// "Mac15,3 · macOS 26.5" line in the iOS discoverable list.
enum MacModelInfo {
    static func currentModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        let result = sysctlbyname("hw.model", &buffer, &size, nil, 0)
        guard result == 0 else { return "Mac" }
        // sysctl may leave the buffer non-null-terminated if
        // size changed between the two calls; trim trailing
        // nulls to be safe.
        let trimmed = buffer.prefix { $0 != 0 }
        let str = String(cString: Array(trimmed))
        return str.isEmpty ? "Mac" : str
    }
}
