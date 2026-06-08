# Security Policy

Doom Coder runs on your machine, edits agent config files in your home directory, and ships unsandboxed on macOS. That means security reports matter. Thanks for helping keep it safe.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.** A public report tells everyone about the hole before there's a fix.

Instead, report it privately one of two ways:

1. **GitHub private advisory (preferred).** Go to the [Security tab](https://github.com/katipally/Doom-Coder/security/advisories/new) and open a draft advisory. This keeps the details private until a fix ships.
2. **Email.** Send the details to yashwanthreddykatipally@gmail.com.

Include as much as you can:

- What the issue is and where in the code or app it lives
- Steps to reproduce it, or a proof of concept
- What an attacker could actually do with it
- Any idea you have for a fix

## What happens next

- I will acknowledge your report as soon as I can, usually within a few days.
- I will confirm whether it's a real issue and figure out how bad it is.
- I will work on a fix and keep you in the loop on timing.
- Once a fix is released, I'm happy to credit you in the release notes if you want, or keep you anonymous if you'd rather.

Please give me a reasonable window to ship a fix before you disclose anything publicly.

## Scope

Things that are in scope:

- The Mac app (`DoomCoder/`) and the `dc-hook` helper binary
- The iOS companion (`DoomCoderCompanion/`) and its notification service extension
- The shared `DoomCoderCore` package
- The hook install and config-editing logic
- The CloudKit sync path and how notification content is handled

Things that are **not** vulnerabilities in this project:

- Bugs in the AI agents themselves (Claude Code, Cursor, Codex, etc.). Report those to their own projects.
- Issues that need an attacker to already have full access to your unlocked Mac.
- Apple framework or macOS bugs. Report those to Apple.

## A note on the unsandboxed Mac app

The Mac app intentionally ships without the App Sandbox. This is a deliberate, documented choice driven by features that the sandbox would block (the global hotkey, power assertions, shelling out to `dc-hook`, and editing agent config files in your home directory). The full rationale is in the [privacy policy](docs/privacy.md#11-why-the-mac-app-is-not-sandboxed-audit-2026-06). The app is signed with an Apple Developer ID, notarized by Apple, and uses no third-party analytics or tracking SDKs. If you find a way this design can be abused, that's exactly the kind of report I want.

## What we collect

Nothing. Doom Coder has no servers, no analytics, and no telemetry. Notifications travel only through your own private iCloud container. See the [privacy policy](docs/privacy.md) for the full story.
