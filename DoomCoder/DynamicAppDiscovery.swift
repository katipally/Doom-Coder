import Foundation
import AppKit

// MARK: - DiscoveredTool

struct DiscoveredTool {
    let id: String           // binary name for CLI; bundle ID for GUI
    let displayName: String
    let kind: Kind
    let installPath: URL?

    enum Kind { case gui, cli }
}

// MARK: - DynamicAppDiscovery

// Scans the user's device for installed AI coding tools with no hardcoded output list.
// Searches all PATH directories, package manager bin locations, and /Applications
// for executables whose names match known AI tool patterns. Also includes tools
// the user has manually added via Settings.
//
// Designed to be called on the @MainActor (NSWorkspace calls require it).
// Safe to call at startup and on manual refresh — not on frequent poll loops.
final class DynamicAppDiscovery {

    // MARK: - Pattern Tables (matching, not output)

    // Known CLI binary names → friendly display names.
    // Any executable found in a search path whose name appears in this map gets tracked.
    static let cliNameMap: [String: String] = [
        "claude":             "Claude Code",
        "copilot":            "GitHub Copilot CLI",
        "codex":              "OpenAI Codex",
        "aider":              "Aider",
        "aider-chat":         "Aider",
        "goose":              "Goose",
        "gemini":             "Gemini CLI",
        "amp":                "Amp",
        "cody":               "Sourcegraph Cody",
        "continue":           "Continue",
        "windsurf":           "Windsurf CLI",
        "cursor":             "Cursor CLI",
        "interpreter":        "Open Interpreter",
        "llm":                "LLM CLI",
        "ollama":             "Ollama",
        "chatblade":          "ChatBlade",
        "sgpt":               "ShellGPT",
        "q":                  "Amazon Q CLI",
        "tabnine":            "Tabnine CLI",
        "sweep":              "Sweep",
        "mentat":             "Mentat",
        "phind":              "Phind CLI",
        "jan":                "Jan CLI",
        "lms":                "LM Studio CLI",
        "mods":               "Mods",
        "gptscript":          "GPTScript",
        "fabric":             "Fabric",
        "gorilla-cli":        "Gorilla CLI",
        "superagent":         "SuperAgent",
        "elia":               "Elia",
        "tgpt":               "TGPT",
    ]

    // Known GUI app bundle IDs → friendly display names.
    static let guiBundleMap: [String: String] = [
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.cursor.cursor":              "Cursor",
        "com.microsoft.VSCode":           "VS Code",
        "com.microsoft.VSCodeInsiders":   "VS Code Insiders",
        "com.exafunction.windsurf":       "Windsurf",
        "dev.zed.Zed":                    "Zed",
        "io.zed.Zed-Preview":             "Zed Preview",
        "com.apple.dt.Xcode":             "Xcode",
        "com.googlecode.iterm2":          "iTerm2",
        "dev.warp.Warp-Stable":           "Warp",
        "com.mitchellh.ghostty":          "Ghostty",
        "com.apple.Terminal":             "Terminal",
        "org.alacritty":                  "Alacritty",
        "com.jetbrains.intellij":         "IntelliJ IDEA",
        "com.jetbrains.pycharm":          "PyCharm",
        "com.jetbrains.webstorm":         "WebStorm",
        "com.jetbrains.rider":            "Rider",
        "com.tabnine.TabNine":            "Tabnine",
        "com.amazon.aws.amazonq":         "Amazon Q",
        "com.sublimehq.sublimetext":      "Sublime Text",
        "com.bolt.New":                   "Bolt",
        "io.void.Void":                   "Void",
        "com.replit.desktop":             "Replit",
    ]

    // MARK: - Scan

    // Discovers all installed AI tools on this device.
    // Merges dynamic filesystem scan with user-configured custom tools from UserDefaults.
    @MainActor
    static func scan() -> [DiscoveredTool] {
        var results: [DiscoveredTool] = []
        var seenIDs = Set<String>()

        func add(_ tool: DiscoveredTool) {
            guard seenIDs.insert(tool.id).inserted else { return }
            results.append(tool)
        }

        // --- CLI Tools: scan all PATH and package manager directories ---
        let fm = FileManager.default
        for dir in cliSearchPaths() {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                guard let displayName = cliNameMap[entry] else { continue }
                let url = URL(fileURLWithPath: "\(dir)/\(entry)")
                add(DiscoveredTool(id: entry, displayName: displayName, kind: .cli, installPath: url))
            }
        }

        // User-configured custom CLI binary names
        let customCLI = UserDefaults.standard.stringArray(forKey: "doomcoder.customCLIBinaries") ?? []
        for binary in customCLI {
            let bin = binary.trimmingCharacters(in: .whitespaces)
            guard !bin.isEmpty else { continue }
            let displayName = cliNameMap[bin] ?? bin
            add(DiscoveredTool(id: bin, displayName: displayName, kind: .cli, installPath: nil))
        }

        // --- GUI Apps: fast path via NSWorkspace Launch Services ---
        for (bundleID, displayName) in guiBundleMap {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                add(DiscoveredTool(id: bundleID, displayName: displayName, kind: .gui, installPath: appURL))
            }
        }

        // Fallback: scan /Applications and ~/Applications for bundle IDs in our map
        let appDirs = [
            "/Applications",
            (("~/Applications") as NSString).expandingTildeInPath,
        ]
        for dir in appDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let plistPath = "\(dir)/\(entry)/Contents/Info.plist"
                guard let plist = NSDictionary(contentsOfFile: plistPath),
                      let bundleID = plist["CFBundleIdentifier"] as? String,
                      let displayName = guiBundleMap[bundleID] else { continue }
                let appURL = URL(fileURLWithPath: "\(dir)/\(entry)")
                add(DiscoveredTool(id: bundleID, displayName: displayName, kind: .gui, installPath: appURL))
            }
        }

        // User-configured custom GUI bundle IDs
        let customGUI = UserDefaults.standard.stringArray(forKey: "doomcoder.customGUIBundles") ?? []
        for bundleID in customGUI {
            let bid = bundleID.trimmingCharacters(in: .whitespaces)
            guard !bid.isEmpty else { continue }
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
            let displayName = appURL?.deletingPathExtension().lastPathComponent ?? bid
            add(DiscoveredTool(id: bid, displayName: displayName, kind: .gui, installPath: appURL))
        }

        return results.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - CLI Search Paths

    // Builds all directories to search for CLI binaries.
    // Sources: system /etc/paths, package manager locations, user-specific dirs.
    static func cliSearchPaths() -> [String] {
        var paths: [String] = []
        let fm = FileManager.default

        // System-defined paths (set by macOS, Homebrew, etc.)
        if let content = try? String(contentsOfFile: "/etc/paths", encoding: .utf8) {
            paths += content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        if let entries = try? fm.contentsOfDirectory(atPath: "/etc/paths.d") {
            for entry in entries.sorted() {
                if let content = try? String(contentsOfFile: "/etc/paths.d/\(entry)", encoding: .utf8) {
                    paths += content.components(separatedBy: .newlines).filter { !$0.isEmpty }
                }
            }
        }

        let home = fm.homeDirectoryForCurrentUser.path

        // Standard package manager and user bin locations
        paths += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-packages/bin",
            "\(home)/.yarn/bin",
            "\(home)/.claude/bin",    // Claude Code native installer
        ]

        // Python user bin dirs (aider, sgpt, llm, etc. install here via pip)
        if let pythonDirs = try? fm.contentsOfDirectory(atPath: "\(home)/Library/Python") {
            for version in pythonDirs {
                paths.append("\(home)/Library/Python/\(version)/bin")
            }
        }

        // nvm-managed Node.js bin dirs (codex, copilot, etc.)
        let nvmBase = "\(home)/.nvm/versions/node"
        if let nodeVersions = try? fm.contentsOfDirectory(atPath: nvmBase) {
            for version in nodeVersions {
                paths.append("\(nvmBase)/\(version)/bin")
            }
        }

        // Volta-managed Node.js tools
        paths.append("\(home)/.volta/bin")

        // Deduplicate while preserving order
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
