# iCloud Shared-Zone (CKShare) — Deploy & Test Guide (schema v3)

This release moves Mac↔iOS sync from the old **same-iCloud / private-database** model
to the Apple-recommended **shared-zone + CKShare** model:

- Each **Mac owns a per-Mac zone** `DoomCoderZone-<macId>` in its private database and
  shares it **zone-wide** via `CKShare(recordZoneID:)` (read-write).
- Each **iPhone/iPad runs TWO `CKSyncEngine`s** — one on its **private** database and one
  on its **shared** database:
  - **Same Apple ID** as the Mac → the Mac's zone is already in the iPhone's *private*
    database (one private DB spans a user's devices), so the Mac is **auto-discovered, no QR
    needed**.
  - **Different Apple ID** → the iPhone accepts the Mac's **CKShare** (QR or link) and the
    zone appears in its *shared* database.
  - Writes (presence, control commands) are routed to whichever database holds that Mac's
    zone. Works with **multiple Macs / multiple iPhones**.
- Push-first: the Mac now has `aps-environment` in Release, so iOS→Mac is instant.

## 1. Deploy CloudKit schema (Development → Production) — REQUIRED

Until this is done, different-iCloud sharing silently fails in Release.

In the **CloudKit Console** (https://icloud.developer.apple.com/dashboard) for container
`iCloud.com.doomcoder.app`:

1. Run both apps once in **Debug** on a device so the new schema auto-creates in the
   **Development** environment:
   - New field on `CompanionStatus`: **`customDeviceName`** (String).
   - `schemaVersion` is now **3** on all record types (no console action — it's a field value).
   - The per-Mac record zones + the zone-wide **CKShare** system type are created at
     runtime; confirm a `cloudkit.share` record type appears.
2. In the Console, **Deploy Schema Changes to Production**. Verify in Production:
   - `CompanionStatus.customDeviceName` exists.
   - Indexes needed for queries still exist (`NotificationLog.ts` queryable for the reaper).
3. Old record types from v2 (MacStatus/NotificationLog/etc.) are unchanged and remain valid.

## 2. Entitlements (already in the repo — verify in your signing setup)

- Mac `DoomCoder.Release.entitlements`: now includes `aps-environment = production` ✅
  (this was missing and is the fix for "iOS→Mac not instant").
- iOS Release: `aps-environment = production` (already present).
- iOS `Info.plist`: `NSCameraUsageDescription` added (QR scanner).
- Both keep CloudKit + App Group entitlements.

## 3. First launch after update (migration)

- **iOS** wipes pre-v3 sync caches once (`AppGroupCache.enforceSchemaVersion` → v3): old
  engine token, server records, learned zones, cached Mac, primary-Mac. The user re-pairs
  once via **Connect ▸ Scan QR** (the "Reconnect" path).
- **Mac** wipes its pre-v3 engine state once (`doomcoder.ckpusher.v3.zoneMigration`) so the
  new per-Mac zone is created cleanly.

## 4. Pairing (how the user connects)

- **Mac:** Configure ▸ **Connections ▸ Add Device** → shows a **QR code** + **Copy Invite
  Link** + Share. (The link is a secret — anyone with it can join + send control commands;
  revoke from the device list.)
- **iPhone:** Connect ▸ **Scan QR Code**, or tap the **invite link** (opens the system
  accept sheet → handled in `AppDelegate.userDidAcceptCloudKitShareWith`).

## 5. Two-device runtime test matrix (Simulator iCloud is flaky — use real devices)

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Same Apple ID: just open the iPhone **Connect** sheet (no QR needed) | iPhone auto-discovers the Mac via the private-DB engine and connects; iPhone shows real Mac name; **Mac shows the iPhone's custom/marketing name + model** (not generic "iPhone"). |
| 2 | Different Apple ID: scan QR / open link | Accept sheet → connected; bidirectional sync; control commands work; Mac device row shows the other account's name/email. |
| 3 | Instant push (signed Release): change state on one side | Appears on the other in <3s without reopening the app; **iOS→Mac instant** (validates the aps-environment fix). |
| 4 | Multi-device: 2 Macs + 2 iPhones; each iPhone scans both Macs | iPhone "Choose your Mac" lists both; switching scopes agents/notifications/commands; each Mac lists its iPhones. |
| 5 | Notifications | A new agent event on the Mac posts a **rich local notification** on the iPhone (icon + session thread) via silent push → fetch → local notif. |
| 6 | Disconnect | iPhone Settings ▸ Disconnect → leaves the share (Mac drops the device); Mac "Forget" removes the presence row. |
| 7 | Relaunch both | Repopulates from the zone; no `CKError 14/2004` loops; presence/last-seen stays live. |

## 6. Known limitations / follow-ups

- Presence (`CompanionStatus`) is published to the **active (primary) Mac's** zone only;
  multi-Mac simultaneous presence-to-all is a follow-up (would need per-zone server-record
  cache keys).
- Mac "Forget" deletes the device's `CompanionStatus`; full CKShare participant revoke is
  available via `MacShareCoordinator.removeParticipant(id:)` but not yet mapped to a
  per-device button (participants are keyed by iCloud user, not deviceId).
- Visible notifications are reconstructed as **local** notifications (the shared database
  can't use `CKQuerySubscription`), gated on the silent-push fetch + the launch/foreground
  fetch fallback.
