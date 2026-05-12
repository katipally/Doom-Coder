# DoomCoderiOS — Xcode setup (manual steps)

The iOS sources under `DoomCoderiOS/Sources/` are a **standalone Swift module**. They are NOT in `DoomCoder.xcodeproj` yet. You must create the iOS target in Xcode GUI and drag the sources in. This file is the canonical step-by-step.

---

## 0. Prerequisites
- Xcode 26 + macOS 26 (already required).
- Apple Developer Program membership active. Team ID: `A9P2388PHM`.
- Signed into Xcode → Settings → Accounts with the same Apple ID.
- A physical iPhone for Live Activity + push verification (Simulator can't do silent CK push end-to-end).

---

## 1. Apple Developer Portal — one-time setup

**1.1 Create iCloud container (shared by Mac + iOS)**
- developer.apple.com → Identifiers → iCloud Containers → `+`.
- Description: `DoomCoder`
- ID: `iCloud.com.doomcoder.app`
- Save.

**1.2 Mac App ID update**
- Identifiers → `com.doomcoder.app` → enable capabilities:
  - iCloud (CloudKit) → select container `iCloud.com.doomcoder.app`.
  - Push Notifications.
  - Background Modes (remote-notification is plist-only, no portal toggle).
- Save → regenerate Mac provisioning profile if Xcode prompts.

**1.3 iOS App ID (new)**
- Identifiers → App IDs → `+` → App.
- Description: `Doom Coder iOS`.
- Bundle ID: explicit, `com.doomcoder.ios`.
- Capabilities to tick:
  - iCloud (CloudKit) → select `iCloud.com.doomcoder.app`.
  - Push Notifications.
  - (Live Activities is plist-only — `NSSupportsLiveActivities = true`.)
- Save.

---

## 2. Xcode project setup

**2.1 Add iOS App target**
- Open `DoomCoder.xcodeproj`.
- File → New → Target → iOS → App.
- Product Name: `DoomCoderiOS`.
- Team: your team (`A9P2388PHM`).
- Organization Identifier: `com.doomcoder` → bundle becomes `com.doomcoder.ios`.
- Interface: SwiftUI · Language: Swift · Storage: None · Tests: include.
- Deployment Target: iOS 26.0.
- Click "Finish". When asked "Activate scheme?" → Yes.

**2.2 Replace stub sources with module**
- In the new target, delete the auto-generated `ContentView.swift` and `DoomCoderiOSApp.swift`.
- Right-click the new target group → "Add Files to DoomCoder…".
- Add the entire `DoomCoderiOS/Sources/` folder as **group references** (not folder reference). Make sure "Add to target: DoomCoderiOS" is ticked.
- Also drag `DoomCoderiOS/Resources/PrivacyInfo.xcprivacy` into the target with "Add to target" ticked.
- Paste the contents of `DoomCoderiOS/Resources/Info.plist.snippet.txt` into the iOS target's auto-generated `Info.plist` (open as Source).

**2.3 Entitlements**
- Replace the Xcode-generated `DoomCoderiOS.entitlements` content with the contents of `DoomCoderiOS/Resources/DoomCoderiOS.entitlements`.
- Signing & Capabilities tab → confirm iCloud + Push Notifications + Background Modes (remote-notifications) are listed and the container is selected.

**2.4 Widget Extension target**
- File → New → Target → iOS → Widget Extension.
- Product Name: `DoomCoderWidget`.
- Bundle Identifier: `com.doomcoder.ios.widget` (Xcode default).
- "Include Live Activity": **YES**.
- "Include Configuration App Intent": NO.
- Finish.
- Delete the auto-generated widget views.
- Drag these files into the widget target (with "Add to target: DoomCoderWidget" ticked only — NOT the main app):
  - `DoomCoderiOS/Sources/LiveActivity/DoomCoderActivityAttributes.swift`
  - `DoomCoderiOS/Sources/LiveActivity/ApprovalIntents.swift`
  - `DoomCoderiOS/Sources/Widget/DoomCoderActivityWidget.swift`
- Also add `DoomCoderActivityAttributes.swift` to the **main app target** (it must be in both — shared between app and widget).
- Widget target entitlements: copy the iOS entitlements file (same container, same aps-environment).

**2.5 App icon + assets**
- Add a 1024×1024 PNG to `Assets.xcassets/AppIcon` for the iOS target.
- Same for the widget extension if it needs its own icon.

---

## 3. CloudKit schema deploy

**3.1 First-run schema creation (Development)**
- Run the iOS app on Simulator once **while CloudKit container is empty** to let it write a single record (any one).
- OR use `cktool` (Apple's CloudKit CLI):
  ```
  xcrun cktool create-record-type --container-id iCloud.com.doomcoder.app --environment development --record-type AgentEvent ...
  ```
  (Repeat for each record type in `Sources/Shared/CloudKitSchema.swift`.)
- Easier path: open the Mac app with `cloudKitEnabled` on, click "Send test event" in Settings — this creates `AgentEvent` and `SessionAggregate` schemas.

**3.2 Mark fields queryable / sortable**
- developer.apple.com → CloudKit Console → your container → Schema → Development → Record Types.
- For each record type, open Indexes and set:
  - `AgentEvent`: sessionKey (queryable), agent (queryable), hookPhase (queryable), occurredAt (queryable + sortable), recordName (queryable).
  - `SessionAggregate`: sessionKey (queryable), lastEventAt (queryable + sortable), status (queryable), recordName (queryable).
  - `ApprovalRequest`: sessionKey (queryable), recordName (queryable).
  - `ApprovalResponse`: requestId (queryable), recordName (queryable).
  - `DevicePresence`: platform (queryable), lastSeenAt (sortable), recordName (queryable).
  - `UserSettings`: recordName (queryable).
- Save.

**3.3 Promote to Production (only before App Store submit)**
- CloudKit Console → Schema → "Deploy Schema Changes…" → Dev → Production.

---

## 4. Build, run, verify

**4.1 First run on Simulator**
- Scheme: DoomCoderiOS → iPhone 16 Pro simulator → Run.
- Sign into iCloud in Simulator (Settings app inside Sim).
- App should launch, request notification permission, show empty Live tab.

**4.2 End-to-end on physical iPhone**
- Plug iPhone in → select as run destination → Run.
- Trust the developer cert on iPhone (Settings → General → VPN & Device Management).
- Sign into the **same iCloud account** as your Mac.
- On Mac: enable CloudKit sync in Settings → run any Claude/Codex/Cursor command → events should push to iPhone within 5-30 seconds.

**4.3 Live Activity verification**
- iOS Settings → Face ID & Passcode → Live Activities → On.
- iOS Settings → Doom Coder → Live Activities → On.
- Trigger any agent command on Mac → Live Activity appears on iPhone Lock Screen + Dynamic Island.

**4.4 Approval round-trip (Phase 4)**
- On Mac, run a Claude Code command that hits PreToolUse for `Bash` (e.g. `Claude → run npm test`).
- Approval notification fires on iPhone within seconds.
- Tap "Approve" → Mac dc-hook receives decision within 60s window → tool runs.

---

## 5. TestFlight + App Store

**5.1 App Store Connect listing**
- appstoreconnect.apple.com → My Apps → `+` → New App.
- Platform: iOS · Name: `Doom Coder` · Primary Language: English (US) · Bundle ID: `com.doomcoder.ios` · SKU: `doomcoder-ios-3000`.

**5.2 Required metadata**
- Subtitle: "Track Claude Code, Cursor, Copilot from your phone".
- Category: Productivity (primary), Developer Tools (secondary).
- Privacy Policy URL: host `privacy.html` on GitHub Pages first (e.g. `https://katipally.github.io/Doom-Coder/privacy`).
- Screenshots: 6.9" iPhone (Pro Max) + 6.5" iPhone — at least 3 each.
- App Privacy: Data Linked to You → "Other Diagnostic Data" (coding sessions); Tracking: NO.
- Export Compliance: `ITSAppUsesNonExemptEncryption = false` (already in plist).

**5.3 TestFlight Internal**
- Archive in Xcode → Window → Organizer → "Distribute App" → "App Store Connect" → "Upload".
- Wait ~15min for processing → App Store Connect → TestFlight → add yourself to Internal Testing group.

**5.4 External beta (≤25 users)**
- TestFlight → External Testing → submit for beta review (~24h).

---

## 6. Manual blockers checklist

| # | Blocker | Who | When |
|---|---|---|---|
| 1 | Create `iCloud.com.doomcoder.app` container | You | Before Phase 3 |
| 2 | Add iCloud cap to `com.doomcoder.app` Mac App ID | You | Before Phase 2 push works |
| 3 | Create `com.doomcoder.ios` App ID | You | Phase 3 |
| 4 | Create Xcode iOS app target + Widget extension | You | Phase 3 |
| 5 | Drag `DoomCoderiOS/Sources/` groups into targets | You | Phase 3 |
| 6 | Deploy CK schema dev → prod | You | Before App Store submit |
| 7 | Create App Store Connect listing + privacy policy + screenshots | You | Phase 6 |
| 8 | Physical iPhone for Live Activity verification | You | Phase 3 testing |
| 9 | TestFlight Internal then External | You | Phase 6 |
| 10 | Delete ntfy code path | (covered in Phase 5 by agent) | After iOS ships |

---

## 7. Troubleshooting

- **No silent push received** → CKSubscription only fires on real device (Simulator unreliable). Verify under Settings → Notifications → Background App Refresh ON.
- **"This container is invalid"** → iCloud container ID typo OR Xcode not regenerated provisioning profile.
- **Live Activity won't start** → check `ActivityAuthorizationInfo().areActivitiesEnabled` and iOS Settings → Doom Coder → Live Activities ON.
- **Approval button does nothing** → LiveActivityIntent requires iOS 17+; on iOS 26 should work. Check that intent target is the **Widget Extension**, not main app.
- **CloudKit schema errors** → Dev environment first. Production schema must match Dev — promote via Console.
