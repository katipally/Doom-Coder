# iPhone Notifications

DoomCoder forwards attention-grabbing agent events (waiting for input / error / done) to your phone over **[ntfy.sh](https://ntfy.sh)** — a lightweight, zero-auth push protocol.

The Mac-side banner fires regardless; this guide covers phone push only.

Open **DoomCoder → Settings → iPhone**.

---

## Setup

1. Install the [ntfy iOS app](https://apps.apple.com/app/ntfy/id1625396347) from the App Store.
2. Toggle ntfy **on** in DoomCoder → Settings → iPhone. DoomCoder auto-generates an unguessable random topic (`doom-<22 hex chars>`).
3. Tap **Subscribe to topic** in the ntfy app and paste the topic name (the part after `ntfy.sh/`).
4. Hit **Send Test** in DoomCoder. A push notification should arrive on your phone within 1–3 seconds.

---

## Privacy & security

- ntfy's public server is zero-knowledge — the topic name is the only thing gating access.
- DoomCoder generates 112 bits of randomness, so the topic is uncrackable by brute force.
- For extra paranoia, self-host ntfy and change the URL in DoomCoder.
- No source code, prompts, or file contents ever leave your Mac — only a short status line and the agent name.

---

## Delivery log

The bottom of the iPhone tab shows the last 50 delivery attempts with timestamp, success/failure flag, and the HTTP status returned by ntfy. Use it to confirm your setup works end-to-end.

---

## Troubleshooting

See [troubleshooting.md](troubleshooting.md) for common issues.
