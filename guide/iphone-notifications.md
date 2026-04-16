# iPhone Notifications

DoomCoder 0.7 introduces **triple-redundant** iPhone notifications. Every attention-grabbing agent event (waiting for input / error / done) fans out to three parallel channels. If one fails, the others still reach your phone.

Open **DoomCoder → Settings → iPhone**.

---

## The three channels

### 1. iCloud Reminders (recommended, zero-setup)

- **How it works:** DoomCoder creates a completed reminder in your default Reminders list. Apple's iCloud sync pushes it to your iPhone within seconds.
- **Setup:** toggle on → click **Grant Access** → approve the Reminders permission prompt.
- **Privacy:** nothing leaves your Mac except via Apple's iCloud sync (end-to-end encrypted).
- **Latency:** typically 1–10 seconds.
- **Works offline:** Mac queues the reminder; it syncs when iCloud reconnects.

### 2. iMessage to yourself

- **How it works:** DoomCoder tells Messages.app to send an iMessage to a handle you configure (your own phone number or Apple ID email).
- **Setup:** toggle on → enter your phone or email → macOS will prompt for AppleEvents permission the first time DoomCoder talks to Messages.
- **Privacy:** standard iMessage pipeline. End-to-end encrypted between your devices.
- **Latency:** usually sub-second.
- **Requirement:** you must be signed in to iMessage on your Mac.

### 3. ntfy.sh (opt-in, cross-platform)

- **How it works:** DoomCoder POSTs to `https://ntfy.sh/<topic>`. Install the [ntfy iOS app](https://apps.apple.com/app/ntfy/id1625396347) and subscribe to the same topic.
- **Setup:** toggle on → DoomCoder auto-generates an unguessable random topic (`doom-<22 hex chars>`) → open the URL on your phone and subscribe.
- **Privacy:** ntfy's public server is zero-knowledge; the topic name is the only authentication. DoomCoder generates 112 bits of randomness so the topic is uncrackable. For extra paranoia, self-host ntfy and change the URL in DoomCoder.
- **Latency:** typically 1–3 seconds.
- **Use when:** you're not on iMessage / iCloud, you want push on Android, or you want one notification channel that works from any device.

---

## Which should I enable?

| Situation | Recommended |
|---|---|
| Just want it to work | Reminders (leave the other two off) |
| Want fastest alert | iMessage + Reminders |
| Don't use iCloud | ntfy only |
| Team / shared alerts | ntfy with a shared topic |
| Paranoid | Reminders only (stays inside Apple) |

Enabling all three is fine — each channel respects a 10-second per-session de-dup window in the Agent Bridge, so you won't get three banners for one event; you'll get one banner **per channel**.

---

## Delivery log

The bottom of the iPhone tab shows the last 50 delivery attempts with timestamp, channel, success/failure flag, and detail. Use it to confirm your setup works end-to-end.

---

## Testing

Each channel card has a **Send Test** button. A single attention event fires through only that channel. If you don't see it on your phone within 30 seconds, the error message in the delivery log explains what went wrong.

---

## Troubleshooting

See [troubleshooting.md](troubleshooting.md) for common issues (permission denied, handle format for iMessage, ntfy not pushing, etc.).
