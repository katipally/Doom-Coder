# Changelog

All notable changes to Doom Coder will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.2] - 2026-04-04

### Fixed
- **Proper bottom-up code signing** — Replaced deprecated `codesign --deep` with individual component signing in the correct order: XPC services → Sparkle helpers → Sparkle framework → main app. This follows Apple's current best practices and produces valid signatures that macOS Sequoia (15+) and macOS 26 accept correctly.
- **Hardened runtime flag on all components** — Every binary now includes `--options runtime` for hardened runtime, matching Xcode's default behavior.
- **Accurate Gatekeeper instructions** — Updated README and release notes with correct macOS Sequoia/26 instructions (System Settings → Privacy & Security → Open Anyway), since Apple removed the right-click bypass in macOS 15.

## [0.1.1] - 2026-04-04

### Fixed
- **"App is damaged" error on macOS 14+** — CI now properly ad-hoc signs the app bundle and all nested Sparkle components (XPCServices, Autoupdate helper, Updater.app) using `codesign --force --deep --sign -`. Previously the build had `CODE_SIGNING_ALLOWED=NO` which produced a completely unsigned binary that macOS 14+ rejects as "damaged".
- Updated installation instructions in README to include the `xattr -cr` Terminal method (works on all macOS versions) alongside the right-click method.

## [0.1.0] - 2026-04-04

### Added
- Initial release 🎉
- Menu bar icon (`⚡` when active, `⚡/` when inactive) — no Dock icon, lives purely in the menu bar
- Toggle to enable/disable sleep prevention with a single click
- Elapsed time display ("Active for 2h 34m") when Doom Coder is running
- Prevents both **display sleep** and **system sleep** using `IOPMAssertionTypePreventUserIdleDisplaySleep` — zero CPU overhead, kernel-level flag
- Sparkle auto-update support — "Check for Updates..." in the menu
- About window with version info
- Launch at login support (requires app to be in `/Applications`)
- Targets macOS 14+ (Sonoma and later)

[0.1.2]: https://github.com/katipally/Doom-Coder/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/katipally/Doom-Coder/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/katipally/Doom-Coder/releases/tag/v0.1.0
