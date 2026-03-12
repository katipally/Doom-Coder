// DataAndPrivacyView.swift — DoomCode Companion
// Dedicated "Data & Privacy" screen pushed from Settings. Gives the user full
// control over what stays and what goes: clear individual categories, or erase
// everything for a fresh-install state. All clearing is LOCAL — iCloud records
// are never touched.

import SwiftUI
import DoomCodeCore

struct DataAndPrivacyView: View {

    /// A single clearable slice of on-device data.
    private struct Category: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let systemImage: String
        let confirmTitle: String
        let confirmButton: String
        let run: () async -> Void
    }

    @State private var pending: Category?
    @State private var showEraseConfirm = false
    @State private var showEraseDone = false
    @State private var busy = false

    private var categories: [Category] {
        [
            Category(
                title: "Prompts & AI chats",
                subtitle: "Your saved prompt drafts and refine conversations.",
                systemImage: "text.bubble",
                confirmTitle: "Delete prompts & AI chats?",
                confirmButton: "Delete prompts & chats",
                run: { CompanionDataManager.clearPromptsAndChats() }
            ),
            Category(
                title: "Notes",
                subtitle: "Every note and checklist on this device.",
                systemImage: "note.text",
                confirmTitle: "Delete all notes?",
                confirmButton: "Delete notes",
                run: { CompanionDataManager.clearNotes() }
            ),
            Category(
                title: "AI keys & settings",
                subtitle: "Removes saved API keys from the Keychain and resets the AI mode.",
                systemImage: "key",
                confirmTitle: "Remove AI keys & settings?",
                confirmButton: "Remove keys",
                run: { CompanionDataManager.clearAIKeysAndSettings() }
            ),
            Category(
                title: "Cached agent data",
                subtitle: "Cached agent lists, notification history and icons. Re-downloads from iCloud for paired Macs.",
                systemImage: "externaldrive.badge.xmark",
                confirmTitle: "Clear cached agent data?",
                confirmButton: "Clear cache",
                run: { CompanionDataManager.clearCachedAgentData() }
            ),
            Category(
                title: "Disconnect all Macs",
                subtitle: "Unpairs every Mac and resets sync. iCloud and the Mac app keep running.",
                systemImage: "minus.circle",
                confirmTitle: "Disconnect all Macs?",
                confirmButton: "Disconnect all",
                run: { await CompanionDataManager.disconnectAllMacs() }
            )
        ]
    }

    var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    Button {
                        Haptics.tap()
                        pending = category
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                    .foregroundStyle(.primary)
                                Text(category.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: category.systemImage)
                                .foregroundStyle(.tint)
                        }
                    }
                    .disabled(busy)
                }
            } header: {
                Text("Clear specific data")
            } footer: {
                Text("Clear only what you choose. Everything here is stored on this device; your iCloud data and your Mac are not affected.")
            }

            Section {
                Button(role: .destructive) {
                    Haptics.warning()
                    showEraseConfirm = true
                } label: {
                    HStack {
                        Label("Erase All Data", systemImage: "trash")
                        if busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(busy)
            } header: {
                Text("Reset")
            } footer: {
                Text("Erases everything on this device — prompts, notes, AI keys, cached data and paired Macs — AND removes this device's data from iCloud, so old agents and notifications don't sync back. This can’t be undone. The app will close when it’s done.")
            }
        }
        .navigationTitle("Data & Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pending?.confirmTitle ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { category in
            Button(category.confirmButton, role: .destructive) {
                runClear(category)
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { _ in
            Text("This can’t be undone.")
        }
        .alert("Erase all data?", isPresented: $showEraseConfirm) {
            Button("Erase Everything", role: .destructive) { runErase() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This wipes all data on this device and deletes this device's zones from iCloud, then closes the app.\n\nIf a Mac on the same iCloud account is still running, it owns its data and may re-publish it — run Erase All Data on the Mac too for a permanent clean slate.")
        }
        .alert("Data erased", isPresented: $showEraseDone) {
            Button("Close DoomCode") { exit(0) }
        } message: {
            Text("All local and iCloud data for this device has been removed. Reopen DoomCode to start fresh.")
        }
    }

    private func runClear(_ category: Category) {
        busy = true
        Task {
            await category.run()
            busy = false
            pending = nil
            Haptics.success()
        }
    }

    private func runErase() {
        busy = true
        Task {
            // Deletes this device's iCloud zones/subscriptions AND all local data,
            // so old agents/notifications don't sync back. Network-dependent — may
            // take a moment.
            await CompanionDataManager.eraseEverything()
            busy = false
            Haptics.success()
            showEraseDone = true
        }
    }
}
