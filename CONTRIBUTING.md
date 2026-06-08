# Contributing to Doom Coder

First off, thanks for being here. Doom Coder started as a fix for one person's annoying problem (Mac falling asleep mid agent run, agents getting stuck on a permission prompt the second I walked away). If you've felt the same pain and want to make this better, you're exactly the right person to contribute.

This guide covers how to set things up, how to send a change, and how to suggest ideas. It's not long. Read it once and you're good.

---

## Ways to contribute

You don't have to write Swift to help.

- **Found a bug?** Open a [bug report](https://github.com/katipally/Doom-Coder/issues/new?template=bug_report.yml).
- **Have an idea?** Open a [feature request](https://github.com/katipally/Doom-Coder/issues/new?template=feature_request.yml). Even a rough one is welcome.
- **Want to write code?** Grab an open issue (look for ones labeled `good first issue` or `help wanted`) or propose your own. Read the [development setup](#development-setup) below.
- **Found a security hole?** Do NOT open a public issue. See [SECURITY.md](SECURITY.md) and email it privately.

If you're unsure whether something is worth doing, open an issue and ask before you spend hours on it. It's always fine to ask first.

---

## Development setup

### What you need

- A Mac running **macOS 26** or later
- **Xcode 26** (the project uses Swift 6 with complete strict concurrency, so older Xcode will not build it)
- For the iOS companion only: **XcodeGen** (`brew install xcodegen`)

### The Mac app

```bash
git clone https://github.com/katipally/Doom-Coder.git
cd Doom-Coder
open DoomCoder.xcworkspace
```

Pick the **DoomCoder** scheme and hit Run. That's it. Swift packages (Sparkle, the shared `DoomCoderCore` package) resolve automatically on first build.

You can build and run the Mac app without any signing certificate. It runs unsigned locally just fine.

### The iOS companion

The iOS project is generated from a spec file (`DoomCoderCompanion/project.yml`) so the `.xcodeproj` stays clean in git. Regenerate it before you open it:

```bash
cd DoomCoderCompanion
xcodegen generate
open DoomCoderCompanion.xcodeproj
```

Build the **DoomCoderCompanion** scheme against any iOS 26 simulator. No signing or Apple Developer account needed for simulator builds.

> If you edit anything about the iOS targets (files added or removed, build settings, entitlements), change it in `project.yml`, not in the generated `.xcodeproj`. The generated project gets overwritten.

---

## How the project is laid out

A quick map so you know where to look:

| Path | What lives here |
|---|---|
| `DoomCoder/` | The macOS app. Menu bar panel, sleep engine, all the UI. |
| `DoomCoder/SleepManager.swift` | The keep-awake core. Holds the IOPMAssertion and owns the Off / On / Auto state. |
| `DoomCoder/AgentTracking/` | Everything about watching agents: hook install, the socket listener, event normalizing, CloudKit push. |
| `dc-hook/` | The tiny helper binary that agents call. Forwards hook events to the app over a Unix socket. |
| `Packages/DoomCoderCore/` | Shared models used by both the Mac app and the iOS companion. |
| `DoomCoderCompanion/` | The iOS companion app and its notification service extension. |
| `docs/` | Public docs: full feature reference, privacy policy, changelog. |

If you're adding agent support or changing notification behavior, you'll mostly live in `DoomCoder/AgentTracking/` and `Packages/DoomCoderCore/`.

---

## Sending a pull request

1. **Fork** the repo and create a branch off `main`. Name it something readable, like `fix-auto-mode-grace` or `add-zed-agent`.
2. **Make your change.** Keep it focused. One PR should do one thing. If you find an unrelated bug along the way, open a separate issue or PR for it.
3. **Match the surrounding code.** Same naming, same comment style, same patterns. Don't reformat files you didn't touch.
4. **Build it.** Make sure both the Mac app and (if you touched it) the iOS companion build cleanly. Warnings are treated as errors in this project, so a warning will fail CI.
5. **Run SwiftLint** locally if you can (`brew install swiftlint` then `swiftlint` from the repo root). CI runs it too.
6. **Open the PR** against `main`. Fill out the template. Explain what changed and why, and link the issue it closes (`Closes #123`).
7. **CI runs automatically.** Three checks: Mac build, iOS build, SwiftLint. All three need to be green.
8. **Respond to review.** I'll usually reply within a few days. Push follow-up commits to the same branch; no need to open a new PR.

### What makes a PR easy to merge

- It does one clear thing and the description says what and why.
- It builds with zero warnings and passes CI.
- It does not bundle a giant unrelated refactor with a small fix.
- It updates the docs in `docs/` or the `README.md` if it changes user-facing behavior.
- It does not add a third-party dependency unless there's a real reason (this app deliberately ships with almost none).

### What slows a PR down

- Reformatting whole files, renaming things nobody asked to rename, or "while I was in here" changes.
- New features with no issue discussion first. Talk about big ideas before building them so you don't waste effort.
- Anything that adds telemetry, analytics, or phones home. This app collects nothing, and that's a hard line.

---

## Coding standards

- **Swift 6, strict concurrency.** The project builds with `SWIFT_STRICT_CONCURRENCY=complete`. Respect actor isolation. If you need `nonisolated(unsafe)` or `@unchecked Sendable`, leave a comment explaining why it's safe, like the existing code does.
- **Warnings are errors.** `SWIFT_TREAT_WARNINGS_AS_ERRORS` is on. A new warning breaks the build.
- **No em dashes or AI filler in docs and comments.** Keep writing plain and direct.
- **Comment the why, not the what.** A header comment on a non-obvious file is great. A comment restating the code is noise.
- **Prefer the standard library and Apple frameworks** over pulling in a dependency.

---

## Suggesting a feature

Open a [feature request issue](https://github.com/katipally/Doom-Coder/issues/new?template=feature_request.yml). Good ones explain:

- The problem you're hitting (not just the solution you imagined)
- How you'd want it to work
- Whether you'd be up for building it yourself

New agent support (a coding agent we don't track yet) is always interesting. If you want to add one, mention which agent and whether it has a hook or plugin system we can tap into.

---

## Code of Conduct

By taking part in this project you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Short version: be decent to people.

---

## Questions

If something here is unclear, open an issue or reach out:

- Email: yashwanthreddykatipally@gmail.com
- LinkedIn: [linkedin.com/in/yashwanth-katipally](https://linkedin.com/in/yashwanth-katipally)

Thanks for helping make Doom Coder better.
