# DoomCoder Companion — Privacy Policy

_Last updated: 2026-05-30_

DoomCoder Companion (iOS) does **not** collect, store, or transmit any personal
data to its developer or any third party.

## What we don't do

- ❌ No analytics SDKs
- ❌ No crash reporting SDKs
- ❌ No advertising identifiers
- ❌ No tracking technologies of any kind
- ❌ No accounts or sign-ins (other than your existing iCloud session)
- ❌ No backend servers operated by us — there are none

## How your data is stored

Your prompts and notes are stored **on your device**. If you pair a Mac, your
notifications, agent configurations, and activity logs are stored in your own
**iCloud Private Database** via Apple's CloudKit service. This means:

- The data is encrypted in transit and at rest by Apple.
- The data is scoped to your Apple ID — no other user can read it.
- The developer of DoomCoder cannot read it.
- If you sign out of iCloud or delete the app, the local cache is removed.
  To delete the cloud copy too, sign in to https://www.icloud.com/, go to
  Settings → Manage Storage → DoomCoder, and choose Delete.

## AI features (optional)

The optional **Enhance** feature can improve a prompt using AI. It runs in one
of two modes that you choose:

- **On-device (Apple Intelligence)** — runs entirely on your device using
  Apple's Foundation Models. No prompt text leaves your device.
- **My API key (BYOK)** — if you provide your own third-party provider key
  (e.g. OpenAI, Anthropic), only the specific text you choose to enhance is
  sent to **that provider you selected** to generate a response, subject to
  that provider's own privacy policy. We do not operate or proxy this request,
  and we receive none of it. Your key is stored only in this device's Keychain.

Prompts and notes never leave your device unless you explicitly use the BYOK
Enhance option on a given piece of text.

## What permissions we request

- **Notifications** — used to deliver note reminders and, when a Mac is paired,
  real-time agent alerts.
- **iCloud** — optional; used only to receive data from a paired Mac.

We do not request location, contacts, photos, microphone, or camera.

## Contact

Questions? Open an issue at https://github.com/katipally/Doom-Coder
