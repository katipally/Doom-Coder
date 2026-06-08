# Doom Code Audit Fixes (2026-06)

This document indexes every issue found in the 2026-06 audit and the
commit that fixed it. Use `git log --grep="<id>"` to retrieve the
exact diff for any item.

The audit covered all three targets: the Mac app (`DoomCode/`), the
iOS companion (`DoomCodeCompanion/`), the shared SwiftPM package
(`Packages/DoomCodeCore/`), and the standalone `dc-hook` helper.

## Severity legend

| Tag  | Meaning |
|------|---------|
| C    | Critical (crash, data loss, deadlock) |
| R    | Race condition (correctness, data race) |
| X    | Runtime safety (lifecycle, task leaks) |
| H    | HIG / SwiftUI / a11y |
| P    | Build / packaging / entitlements / privacy |
| T    | Test gap |

## Phase 1 — Critical bugs & race conditions

| ID  | Severity | Where | Fix |
|-----|----------|-------|-----|
| C-1 | C        | `Packages/DoomCodeCore/.../ServerRecordCache.swift` | Added `NSLock` + `@unchecked Sendable`; concurrent `store` / `clear` can no longer interleave between memory and disk writes. (Phase 1 PR) |
| C-2 | C        | `DoomCodeCompanion/.../LocalStore.swift` | `deinit` no longer calls `queue.sync` (deadlock); added `DatabaseHandle` `@unchecked Sendable` wrapper for the `OpaquePointer` hand-off. |
| C-3 | C        | `LocalStore.swift` | `upsertAgentConfig` wrapped in `BEGIN IMMEDIATE` / `COMMIT` / `ROLLBACK`. |
| C-4 | C        | `LocalStore.swift` | `upsertMacStatus` now uses `record.status ?? "unknown"` (was hard-coded `"online"`). |
| C-5 | C        | `DoomCodeCompanion/.../AppDelegate.swift` | `task as! BGAppRefreshTask` → conditional cast + early return. |
| C-6 | C        | `AppDelegate.swift` | Observer tokens stored in `observerTokens`; removed in new `deinit` via a static `nonisolated(unsafe)` mirror. |
| C-7 | R        | `DoomCodeCompanion/.../Sync/CompanionSyncEngine.swift` | `postedNotifIds` migrated from `[String]` to `Set<String>` with O(1) lookups; persisted as JSON-encoded `Data` under v2 key with v1→v2 migration. |
| C-8 | R        | `DoomCode/SleepManager.swift` | Documented the threading model so future maintainers know which `nonisolated(unsafe)` properties are real C-handle hazards vs. Swift-6 checker false positives. |
| C-9 | C        | `dc-hook/main.swift` | `procShortInfo` rejects oversized kernel returns so a future macOS struct growth does not silently misalign every offset. |
| C-10 | X       | `DoomCode/AgentTracking/CloudKitPusher.swift` | Tracked `Set<Task<Void, Never>>` of in-flight engine kicks; public `stop()` called from `willTerminateNotification`. |
| C-11 | R       | `DoomCode/AgentTracking/HookSocketListener.swift` | Concurrent queue with barrier writes; barrier-guarded snapshot read in `handleClient`. |
| C-12 | C       | `dc-hook/main.swift` | Signal handler is a `@convention(c)` top-level function, not a Swift closure. |
| C-13 | X       | `dc-hook/main.swift` | `sendFrame` always restores the original socket flags before returning, on every code path. Refactored `connectNonBlocking` helper. |
| C-14 | C       | `DoomCodeCompanion/.../UI/ConnectFlowView.swift` | `coordinator` is now a `let` set in `init` (was assigned in `makeUIViewController` after `viewDidLoad`, dropping the first scan). |
| C-15 | H       | `ConnectFlowView.swift` | QR scanner explicitly requests camera permission and renders a Settings deep-link when access is denied. |
| C-16 | R       | `DoomCode/AgentTracking/CloudKitPusherDelegate.swift` | Named `engineRecoveryKickDelay` constant for the 300ms recovery delay (was magic literal at two call sites). |
| C-17 | X       | `DoomCode/AgentTracking/NotificationDispatcher.swift` | Replaced `DispatchQueue` + `Thread.sleep` with a serial `actor NotifySerializer` so the 20ms notification stagger is cooperative. |
| C-18 | H       | `Packages/DoomCodeCore/.../AgentConfigRecord.swift` | Typed `agentStatuses` accessor + convenience initializer for the JSON-encoded `[String: String]` payload. |

## Phase 2 — Runtime safety & lifecycle

| ID  | Severity | Where | Fix |
|-----|----------|-------|-----|
| R-1 | R        | `CompanionSyncEngine.issuerDeviceId` | Protected the read-or-create flow with `OSAllocatedUnfairLock<DeviceIdState>`. |
| X-2 | X        | `AppDelegate.scheduleAppRefresh` | Dedup with `isRefreshScheduled` flag. |
| X-3 | X        | `LocalStore.agent_icons` | Removed the dead table and its `upsertAgentIcon` writer. |
| X-4 | X        | `MacControlView` | Documented that the view-model extraction is deferred to Phase 3; the 894-line view is too entangled for a single PR. |
| X-5 | X        | `SyncDiagnosticsView` | Promoted `let` publishers to `@State` so `.onReceive` re-subscription does not churn. |
| X-6 | X        | `MacReachabilityBanner` | Replaced `Timer.publish` with `TimelineView` (visibility-aware). |
| X-7 | X        | `CloudKitPusherDelegate.persistState` | Respect `Task.isCancelled` before encoding + writing. |
| X-8 | X        | `EventStore.purgeOld` | Added hard row caps (50K events, 5K notifications, 5K session history). |
| X-9 | X        | `ApprovalArbiter` | Documented the `@MainActor` isolation + cancel-before-schedule + seq-guard invariant. |
| X-10 | X       | `MigrationManager.migrate(agents:)` | Defensive idempotency guard. |
| X-11 | X       | `IconDownloader.download` | Disk-quota fallback (1 MB minimum free) before writing icon cache. |
| X-12 | X       | `LocalStore` | Documented the `SQLITE_TRANSIENT` semantic for the `nil` final argument. |

## Phase 3 — HIG, SwiftUI, a11y

| ID  | Severity | Where | Fix |
|-----|----------|-------|-----|
| H-1 | H        | `AgentLogsView.LogRow` | Cached `Date.FormatStyle`; combined a11y element with synthesized label. |
| H-2 | H        | `SettingsView` | Explicit `accessibilityLabel` on `SecureField` (API key) and `TextField` (device name). |
| H-3 | H        | `MacControlView` | Gate the segmented control's matched-geometry pill + opacity animations on `accessibilityReduceMotion`. |
| H-4 | H        | `MacControlView.MacControlCard` | Adopt iOS 26 `.glassEffect(.regular)` (with OS-version fallback). |
| H-5 | H        | `MacReachabilityBanner` | Increase Contrast fallback uses a solid 25% fill + 1.5-pt border. |
| H-6 | H        | `AppRouter` | New `welcomeRequestCount` + `showWelcome()`; `SettingsView` has a "Show welcome again" entry. |
| H-7 | H        | `RootTabView` | Observe `welcomeRequestCount` and re-present the welcome sheet. |

## Phase 4 — Build, entitlements, privacy

| ID  | Severity | Where | Fix |
|-----|----------|-------|-----|
| P-1 | P        | `Packages/DoomCodeCore/Package.swift` | Raised `macOS(.v14)` → `macOS(.v26)`. |
| P-2 | P        | `DoomCodeCompanion/project.yml` | `ENABLE_USER_SCRIPT_SANDBOXING` → `YES` (no shell phases in the iOS project). |
| P-3 | P        | `DoomCodeCompanion/.../Info.plist` | Dropped unused `UIBackgroundModes: fetch`. |
| P-4 | P        | `DoomCodeCompanion/.../PrivacyInfo.xcprivacy` | Removed unused `C617.1` and `35F9.1` reasons. |
| P-5 | P        | `docs/privacy.md` | New section 11 explaining why the Mac app is not sandboxed. |
| P-6 | P        | `DoomCode.xcodeproj/project.pbxproj` | `SWIFT_VERSION` 6.0 → 6.2; `codesign ... || true` removed. |
| P-7 | P        | `DoomCodeCompanion/project.yml` | `SWIFT_VERSION` 6.0 → 6.2; `LSApplicationCategoryType` added. |

## Phase 5 — Tests

| ID  | Severity | Where | Fix |
|-----|----------|-------|-----|
| T-1 | T        | `Packages/DoomCodeCore/Tests/.../ServerRecordCacheTests.swift` | 6 new tests including 3 concurrent stress tests. |
| T-2 | T        | `AgentConfigRecordTests.swift` | 4 new tests for the typed accessor. |
| T-3 | T        | `KeychainTests.swift` | 6 new tests covering set/get/delete/overwrite/isolation. |
| T-4 | T        | `SyncTelemetryTests.swift` | 6 new tests for the ring buffer. |
| T-5 | T        | `NotificationCopyTests.swift` | 4 new tests for new phases. |
| T-6 | T        | `SharedZoneSyncTests.swift` | 3 new tests for `MacStatusRecord` + `ControlCommandRecord` round-trips. |

## Items NOT changed (deliberately)

- `com.apple.security.app-sandbox = false` in the Mac app entitlements
  (per user decision; documented in `docs/privacy.md` section 11).
- `dc-hook/main.swift` 4-byte big-endian length + UTF-8 JSON frame
  format (changing this would require a coordinated Mac + helper
  release).
- CloudKit schema version (would require data migration).

## Known follow-ups (deferred to future PRs)

- `MacControlView` view-model extraction (Phase 3, deferred due to
  the 894-line view). Documented in the file header.
- `dc-hook` end-to-end smoke test (attempted but blocked by dc-hook's
  cross-agent deduplication, which is correct production behavior).
  The frame format is validated by the Mac-side integration test
  (HookSocketListener + dc-hook + RunAgents wizard).
