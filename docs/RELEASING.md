# Releasing DoomCoder

DoomCoder ships through **two independent pipelines** because the Mac app
and the iPhone companion live in different Apple distribution channels.
This document explains both, including the one-time setup each requires.

> Sparkle does **not** and **cannot** update an App Store app. If you
> ever find yourself reaching for `appcast.xml` in the iOS pipeline,
> stop — that is a Mac-only concept.

---

## TL;DR — release commands

| Pipeline | Tag                  | Workflow                               | Ships via            |
| -------- | -------------------- | -------------------------------------- | -------------------- |
| macOS    | `git tag v2.5.0`     | `.github/workflows/release.yml`        | GitHub Releases + Sparkle appcast |
| iOS      | `git tag ios-v2.5.0` | `.github/workflows/ios-testflight.yml` | TestFlight → App Store review |

Both are pushed with `git push --tags` (or as separate single-tag pushes).
The user keeps an "exploratory work is local-only" rule, so push the tag
only when you've explicitly decided to cut the release.

```
git tag v2.7.0
git push origin v2.7.0

git tag ios-v2.7.0
git push origin ios-v2.7.0
```

---

## macOS release (existing, unchanged)

1. Bump `CFBundleShortVersionString` + `CFBundleVersion` in
   `DoomCoder/Info.plist`. `release.yml` also stamps the tag-derived
   version into the plist at build time, but committing the bump keeps
   local dev builds in sync with what shipped.
2. Update `docs/CHANGELOG.md`.
3. `git tag v2.5.0 && git push origin v2.5.0`.
4. `release.yml` (`runs-on: macos-26`) does the rest:
   - Builds + notarizes the `.app` with the existing Developer ID cert.
   - Creates a `.dmg` and signs the Sparkle update with the EdDSA key.
   - Publishes the GitHub Release with the DMG attached.
   - Updates `appcast.xml`. Running Mac clients pick up the update the
     next time Sparkle polls.

Required secrets/vars (already configured):
`APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`,
`APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`.

---

## iOS release (new — TestFlight)

The iPhone companion is distributed through the App Store. Every
TestFlight build automatically becomes available to internal testers;
external testers and the public App Store require Apple review (usually
< 24 h after the first build of a version is reviewed; subsequent
builds with the same marketing version are typically auto-approved).

### One-time setup (you do this once in App Store Connect)

1. **App Store Connect → My Apps → +** → New App.
   - Platform: iOS
   - Name: `DoomCoder Companion`
   - Bundle ID: `com.doomcoder.app.companion`
   - SKU: `doomcoder-companion`
2. **Users and Access → Integrations → App Store Connect API → Generate API Key**.
   - Role: `App Manager` (Admin works but is broader than needed).
   - Download the `AuthKey_XXXXXXXXXX.p8` file. You cannot re-download it.
3. **Certificates, Identifiers & Profiles**:
   - Create an `Apple Distribution` certificate (or reuse an existing one).
   - Export the cert + private key as a `.p12` from Keychain Access.
4. **GitHub repo → Settings → Secrets and variables → Actions**, add:

   | Name                                | Source                                            |
   | ----------------------------------- | ------------------------------------------------- |
   | `APP_STORE_CONNECT_KEY_ID`          | 10-char ID from step 2                            |
   | `APP_STORE_CONNECT_ISSUER_ID`       | Issuer UUID from step 2                           |
   | `APP_STORE_CONNECT_PRIVATE_KEY`     | `base64 -i AuthKey_XXX.p8` of step 2 file         |
   | `IOS_DISTRIBUTION_CERTIFICATE`      | `base64 -i Distribution.p12` of step 3 file       |
   | `IOS_DISTRIBUTION_CERT_PASSWORD`    | Password you used when exporting the .p12         |
   | `IOS_KEYCHAIN_PASSWORD`             | Any random string — used only on the CI runner    |

5. **GitHub repo → Settings → Secrets and variables → Actions → Variables**, add:

   | Name              | Value                                             |
   | ----------------- | ------------------------------------------------- |
   | `APPLE_TEAM_ID`   | Your team ID (e.g. `A9P2388PHM`)                  |

### Cutting an iOS release

1. Bump `MARKETING_VERSION` in `DoomCoderCompanion/project.yml` and run
   `cd DoomCoderCompanion && xcodegen generate`.
2. Update `docs/CHANGELOG.md` (the same section that documents the matching
   Mac release).
3. `git tag ios-v2.4.0 && git push origin ios-v2.4.0`.
4. `ios-testflight.yml` runs on `macos-26`:
   - Regenerates the project with XcodeGen.
   - Stamps `CFBundleShortVersionString` from the tag and a timestamp-
     based `CFBundleVersion` so every build is monotonically newer.
   - Imports the Apple Distribution cert into a throwaway keychain.
   - Archives with `-allowProvisioningUpdates` + the App Store Connect
     API key so Xcode auto-creates the App Store distribution profile.
   - Exports with `destination=upload` so `xcodebuild` itself uploads to
     App Store Connect (no `altool`, no `Transporter.app`).
5. **App Store Connect → TestFlight** — the build appears in 5-20 min,
   pending automated processing.
6. Once the build is finished processing:
   - **Internal testing** (up to 100 testers in your team): instant.
   - **External testing**: submit for "Beta App Review" (first build per
     version; subsequent builds skip review).
   - **App Store release**: submit for review, then `Manually release`
     or `Automatic release after approval`.

### Manual upload (escape hatch)

If you ever need to upload without GitHub Actions, run from a Mac:

```bash
cd DoomCoderCompanion
xcodegen generate
xcodebuild -project DoomCoderCompanion.xcodeproj \
  -scheme DoomCoderCompanion -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/DoomCoderCompanion.xcarchive \
  archive
xcodebuild -exportArchive \
  -archivePath build/DoomCoderCompanion.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export \
  -allowProvisioningUpdates
xcrun altool --upload-app -f build/export/DoomCoderCompanion.ipa \
  --type ios \
  --apiKey "$APP_STORE_CONNECT_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
```

(Drop the App Store Connect key file at
`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` so altool can find
it. The key ID must match.)

---

## Versioning conventions

- The Mac and iOS apps share a marketing version (e.g. `2.4.0`) so a
  user looking at "About" in either app sees the same number when they
  were released as a pair.
- CFBundleVersion (build number):
  - Mac: derived from the marketing version (`major*1000 + minor*100 + patch`).
  - iOS: timestamp-based (`YYYYMMDDHHMM`). App Store Connect requires a
    strictly increasing build number for every upload of the same
    marketing version; timestamps trivially satisfy this without any
    repo bookkeeping.
- Pre-releases for the Mac use `vX.Y.Z-betaN` tags; the iOS pipeline
  doesn't need a beta channel — TestFlight *is* the beta channel.

---

## Pre-flight checklist (per release)

- [ ] `docs/CHANGELOG.md` updated and dated.
- [ ] `MARKETING_VERSION` bumped in `DoomCoder/Info.plist` and
      `DoomCoderCompanion/project.yml`. Companion project regenerated
      with `xcodegen generate`.
- [ ] `CloudKit Dashboard → Schema → Deploy to Production` if any new
      record types or fields landed in this release. (For 2.4.0 this
      means deploying the `installedAgents` + `statuses` additions to
      `AgentConfig`.)
- [ ] App Store Connect screenshots / metadata updated if the iOS UI
      changed visibly.
- [ ] Mac build runs clean locally (`xcodebuild -scheme DoomCoder -configuration Release`).
- [ ] iOS build runs clean locally (`xcodebuild -scheme DoomCoderCompanion -configuration Release -destination 'generic/platform=iOS'`).
- [ ] Both tags pushed. CI green on both workflows.

---

## First-time iOS App Store setup (do once)

This is the walkthrough you only do once per app, before the very first
TestFlight upload. Allow ~60 minutes the first time.

### 1. App Store Connect — create the app record

1. Visit [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
   → **My Apps** → **+** → **New App**.
2. Fill in:
   - **Platform**: iOS
   - **Name**: `DoomCoder Companion`
   - **Primary Language**: English (U.S.)
   - **Bundle ID**: `com.doomcoder.app.companion` (must already exist
     in the Developer Portal under Identifiers)
   - **SKU**: `doomcoder-companion-ios`
   - **User Access**: Full Access
3. Apple assigns a numeric **Apple ID** (e.g. `6480000000`). Note it.
   Update `companionAppStoreURL` in
   `DoomCoder/ConfigureSettingsPane.swift` to replace the
   `id0000000000` placeholder.

### 2. App Store listing metadata

In the app record → **App Store** tab:

- **Category**: Developer Tools / Productivity
- **Content rights**: No third-party content
- **Age rating**: questionnaire (defaults yield 4+)
- **Privacy policy URL**: link to `docs/privacy.md` on GitHub (`https://github.com/katipally/Doom-Coder/blob/main/docs/privacy.md`)
- **Support URL**: `https://github.com/katipally/Doom-Coder`
- **Marketing URL**: optional

### 3. Privacy nutrition label

App Store Connect → **App Privacy** → **Get Started**.

DoomCoder Companion collects **nothing**. The correct answers:

- Data collected: **No**
- Tracking: **No**

This nutrition label is shown on the App Store product page and is
mandatory before submission.

### 4. Screenshots (required)

Apple requires screenshots for at least **one device class**. The
6.7-inch iPhone class (e.g. iPhone 17 Pro Max) is the easiest because
its screenshots are reused for every smaller class automatically.

Required: 3-10 PNG/JPEG screenshots, **1290×2796** (portrait) or
**2796×1290** (landscape).

Quick way:
```bash
xcrun simctl boot "iPhone 17 Pro Max"
open -a Simulator
# Build & run the companion in this simulator
xcrun simctl io booted screenshot ~/Desktop/companion-1.png
```

Suggested shots: agent list, agent detail view, log empty state,
onboarding step, notification arriving (lock screen demo if possible).

### 5. Certificates & provisioning (one-time)

In **Developer Portal → Certificates, Identifiers & Profiles**:

1. **Identifiers** — verify all three App IDs exist:
   - `com.doomcoder.app.companion` (App, with iCloud + Push + App Groups)
   - `com.doomcoder.app.companion.NotificationService` (App Extension, with App Groups)
   - `com.doomcoder.app` (Mac, with iCloud + App Groups)
2. **App Groups** — verify `group.com.doomcoder.app.companion` exists
   and is enabled on all three identifiers.
3. **Certificates** — create an **Apple Distribution** certificate
   (covers both iOS and macOS App Store). Download as `.cer`, double-click
   into Keychain, then export from Keychain Access as a **.p12** with a
   password. Base64-encode it (`base64 -i AppleDistribution.p12 -o cert.b64`)
   and store as the `IOS_DISTRIBUTION_CERTIFICATE` GitHub secret.
4. **Profiles** — leave to Xcode automatic signing. The CI workflow
   uses `-allowProvisioningUpdates` so profiles are minted on demand.

### 6. App Store Connect API key (one-time)

Used by `xcodebuild -exportArchive` to authenticate uploads non-interactively.

1. App Store Connect → **Users and Access** → **Integrations** → **App Store Connect API**.
2. **+** → name `DoomCoder CI`, access `App Manager`.
3. Download the `.p8` (you can only download it **once**).
4. Note the **Issuer ID** (top of the page) and **Key ID** (next to the key).
5. Add as GitHub repo secrets:
   - `APP_STORE_CONNECT_KEY_ID`
   - `APP_STORE_CONNECT_ISSUER_ID`
   - `APP_STORE_CONNECT_PRIVATE_KEY` — paste the **raw .p8 contents**
     (including `-----BEGIN PRIVATE KEY-----` lines).

### 7. CloudKit production deploy (one-time per schema change)

[CloudKit Dashboard](https://icloud.developer.apple.com/dashboard/) →
container `iCloud.com.doomcoder.app` → **Schema** → **Deploy Schema to
Production**. Required before the App Store build can talk to the
production CloudKit environment.

### 8. First TestFlight build

After everything above is done:

```bash
git tag ios-v2.4.0
git push origin ios-v2.4.0
```

The `ios-testflight.yml` workflow runs and uploads to App Store
Connect. The build appears under **TestFlight** in ~10-20 min.

### 9. Submit for App Store review

1. App Store Connect → your app → **App Store** tab → **+ Version**.
2. Fill **What's New in This Version** (paste from CHANGELOG.md).
3. **Build** → pick the TestFlight build you just uploaded.
4. **Submit for Review**.

Review usually takes 24-48 hours. Common rejections to pre-empt:

- Missing privacy policy URL. Ours is at `https://github.com/katipally/Doom-Coder/blob/main/docs/privacy.md`.
- Demo account credentials required if the app has a login. DoomCoder
  Companion does not. In the **Notes for Reviewer** field state: "The
  Prompts and Notes tabs work fully without any Mac connection or API
  key. The Dashboard tab is optional and clearly labeled as requiring
  the Mac app. Apple Intelligence is used for Enhance on supported
  devices; if unavailable the app shows clear guidance and all other
  features remain fully usable. No demo account is needed."
- Background modes not justified. Our `Info.plist` only enables
  `remote-notification`, which CloudKit subscriptions legitimately
  require.

---

## Does iOS use GitHub Releases or Sparkle?

**No.** App Store apps cannot be updated by Sparkle (Apple prohibits
side-loaded update mechanisms in App Store binaries) and cannot be
distributed as `.ipa` from GitHub Releases (Apple TOS).

The iOS pipeline ends at App Store Connect. We do still cut a matching
GitHub Release for the iOS tag (`ios-v2.4.0`) but it carries only the
changelog and a link to the App Store — no binary attachment.

If you want the GitHub Release to be created automatically on tag
push, extend `ios-testflight.yml` with a final
`softprops/action-gh-release@v2` step that publishes notes from
`CHANGELOG.md`. We're keeping that manual for now so the Release
goes live only after Apple actually approves the build.
