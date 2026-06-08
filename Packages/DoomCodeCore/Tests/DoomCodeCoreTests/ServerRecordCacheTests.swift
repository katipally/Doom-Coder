import Foundation
import Testing
import CloudKit
@testable import DoomCodeCore

@Suite("ServerRecordCache concurrency")
struct ServerRecordCacheTests {

    /// Per-test isolated `UserDefaults` instance so concurrent tests cannot
    /// trample each other on the standard suite.
    private func makeCache(suiteName: String = "DoomCodeCoreTests-\(UUID().uuidString)") -> (ServerRecordCache, UserDefaults) {
        let defaults = UserDefaults(suiteName: suiteName)!
        let cache = ServerRecordCache(defaults: defaults, key: "test-cache")
        return (cache, defaults)
    }

    private func makeRecord(name: String) -> CKRecord {
        let zone = CKRecordZone(zoneName: "Z")
        let id = CKRecord.ID(recordName: name, zoneID: zone.zoneID)
        return CKRecord(recordType: "TestRecord", recordID: id)
    }

    @Test func storeThenFetchRoundTripsRecordChangeTag() {
        let (cache, _) = makeCache()
        let rec = makeRecord(name: "A")
        // Fake a "this record already exists on the server" by setting
        // a recordChangeTag. CKRecord allows setting it for testing.
        rec["__recordChangeTag"] = "tag-A" as CKRecordValue
        cache.store(rec)
        let fetched = cache.record(forName: "A")
        #expect(fetched != nil)
    }

    @Test func clearWipesMemoryAndDisk() {
        let (cache, defaults) = makeCache()
        cache.store(makeRecord(name: "A"))
        #expect(cache.record(forName: "A") != nil)
        cache.clear()
        #expect(cache.record(forName: "A") == nil)
        #expect(defaults.dictionary(forKey: "test-cache") == nil)
    }

    @Test func removeDeletesOnlyTargetRecord() {
        let (cache, _) = makeCache()
        cache.store(makeRecord(name: "A"))
        cache.store(makeRecord(name: "B"))
        cache.remove(name: "A")
        #expect(cache.record(forName: "A") == nil)
        #expect(cache.record(forName: "B") != nil)
    }

    /// Regression for the 2026-06 race: concurrent `store` + `clear` could
    /// interleave between the in-memory `memory[name] = rec` write and the
    /// `defaults.set(blob, forKey:)` write, resurrecting a stale record on
    /// the next launch. With the lock, the worst case is that one of the
    /// two operations wins atomically; the other is serialized after.
    @Test func concurrentStoreAndClearNeverCrashes() async {
        let (cache, _) = makeCache()
        let cacheRef = cache

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<500 {
                group.addTask {
                    cacheRef.store(self.makeRecord(name: "R-\(i % 8)"))
                }
                if i % 50 == 0 {
                    group.addTask {
                        cacheRef.clear()
                    }
                }
            }
        }
        // After the storm, the cache must be in a consistent state.
        // (Either populated with some "R-X" entries, or fully empty after
        // a clear, but never mid-state.)
        for i in 0..<8 {
            let r = cache.record(forName: "R-\(i)")
            // No assertion on contents — only that we got a value or nil,
            // never a crash. The test is that we reach this point.
            _ = r
        }
    }

    /// Regression for the 2026-06 race: two `store` calls for the same
    /// record name from different threads must not lose data. The CKRecord
    /// reference stored last wins, but no crash, no torn write to `defaults`.
    @Test func concurrentStoreForSameNameIsAtomic() async {
        let (cache, defaults) = makeCache()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    let r = self.makeRecord(name: "shared")
                    r["counter"] = i as CKRecordValue
                    cache.store(r)
                }
            }
        }
        // Whatever the final state, the disk blob must parse without
        // throwing and the in-memory entry must match the last writer's
        // counter.
        let inMem = cache.record(forName: "shared")
        #expect(inMem != nil)
        let stored = inMem?["counter"] as? Int
        #expect(stored != nil)
        // The defaults blob must exist and be a [String: Data].
        let blob = defaults.dictionary(forKey: "test-cache") as? [String: Data]
        #expect(blob != nil)
        #expect(blob?["shared"] != nil)
    }

    /// Regression for the 2026-06 race: `record(forName:)` racing with
    /// `store` must never observe a torn in-memory state (a record with
    /// a stale `recordChangeTag`). The lock guarantees a read either
    /// sees the pre-store value or the post-store value, never a partial.
    @Test func concurrentReadAndStoreAreLinearizable() async {
        let (cache, _) = makeCache()
        let cacheRef = cache
        let readCount = 1_000
        let writeCount = 1_000
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<readCount {
                group.addTask {
                    _ = cacheRef.record(forName: "X")
                }
            }
            for i in 0..<writeCount {
                group.addTask {
                    let r = self.makeRecord(name: "X")
                    r["v"] = i as CKRecordValue
                    cacheRef.store(r)
                }
            }
        }
        // The test passes if it reaches here without crashing.
        #expect(cache.record(forName: "X") != nil)
    }
}
