// SameIcloudTab.swift — DoomCoder Companion
// v5.1: the 4th tab in the iOS Add Mac sheet. Shows a list of
// Macs that have published a DiscoverableMac record to the
// public DB. Each row is classified as "On the same iCloud" /
// "Different iCloud" client-side by comparing the Mac's
// `publishedBy` field against the iOS app's own user record
// name. Tapping a row writes a CSC{pending,origin:ios} to the
// public DB with `iosUserRecordID` set, then waits for the
// Mac's CSC{accepted} or CSC{denied} response.
//
// The authoritative same-iCloud check happens at probe time on
// the Mac side (it compares the CSC's creatorUserRecordID
// against its own userRecordID). The badge here is a hint to
// save the user a tap if we already know it's a different
// iCloud.

import SwiftUI
import DoomCoderCore

struct SameIcloudTab: View {
    let subscription: DiscoverableMacSubscription
    let coordinator: IOSPairingCoordinator
    @State private var selectedMac: DiscoverableMacRecord?
    @State private var isPairing = false
    @State private var pairingError: String?

    private var sortedDiscovered: [DiscoverableMacRecord] {
        // Same-iCloud rows first, then by lastSeen descending.
        subscription.discovered.sorted { a, b in
            let aSame = subscription.isSameICloudAccount(a)
            let bSame = subscription.isSameICloudAccount(b)
            if aSame != bSame { return aSame }
            return a.lastSeen > b.lastSeen
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            if subscription.localUserRecordName == nil {
                iCloudRequired
            } else if subscription.discovered.isEmpty {
                emptyState
            } else {
                list
            }
            if let err = pairingError {
                errorBanner(err)
            }
        }
        .padding(.top, 12)
        .onAppear {
            Task { await subscription.refresh() }
        }
        .sheet(item: $selectedMac) { mac in
            SameIcloudPairSheet(
                mac: mac,
                isSameICloud: subscription.isSameICloudAccount(mac),
                isPairing: $isPairing,
                error: $pairingError
            ) {
                await coordinator.requestPairFromDiscoverableMac(mac)
            }
        }
        .refreshable {
            await subscription.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectionPairDenied)) { note in
            // v5.1: Mac denied a same-iCloud pair request. The
            // placeholder Connection is now .removed; dismiss
            // the pair sheet and show an inline error so the
            // user knows what happened.
            isPairing = false
            pairingError = "The Mac user denied the pairing request."
            selectedMac = nil
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(sortedDiscovered, id: \.recordName) { mac in
                    MacDiscoverableRow(
                        mac: mac,
                        isSameICloud: subscription.isSameICloudAccount(mac),
                        onTap: {
                            pairingError = nil
                            selectedMac = mac
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var iCloudRequired: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Sign in to iCloud")
                .font(.headline)
            Text("This feature needs an iCloud account on this iPhone. Open Settings and sign in to iCloud to discover Macs on the same account.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if subscription.isLoading {
                ProgressView()
                    .controlSize(.large)
                Text("Looking for Macs…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("No Macs found")
                    .font(.headline)
                Text("Make sure DoomCoder is running on the Mac you want to pair with. It will appear here within a few minutes.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            }
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(msg)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
    }
}

// MARK: - Row

private struct MacDiscoverableRow: View {
    let mac: DiscoverableMacRecord
    let isSameICloud: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "macbook")
                    .font(.title3)
                    .foregroundStyle(isSameICloud ? Color.blue : Color.green)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mac.name)
                            .font(.headline)
                        if isSameICloud {
                            Label("Same iCloud", systemImage: "checkmark.seal.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.blue)
                        }
                    }
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mac.name), \(subtitleText), \(isSameICloud ? "same iCloud" : "different iCloud")")
    }

    private var subtitleText: String {
        var parts: [String] = [mac.model, mac.systemVersion]
        parts.append("Last seen \(mac.lastSeen.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pair sheet

private struct SameIcloudPairSheet: View {
    let mac: DiscoverableMacRecord
    let isSameICloud: Bool
    @Binding var isPairing: Bool
    @Binding var error: String?
    let onPair: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .padding(.top, 24)
                Text("Pair with \(mac.name)?")
                    .font(.title3.weight(.semibold))
                Text(verificationText)
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                if !isSameICloud {
                    Text("This Mac is on a different iCloud account. You'll be asked to confirm the pairing on the Mac before any data is shared.")
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                }
                if let err = error {
                    Text(err)
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                }
                Spacer()
                Button {
                    Task {
                        isPairing = true
                        error = nil
                        await onPair()
                        isPairing = false
                        // Dismiss on success — the coordinator's
                        // phase change will fire .active and the
                        // AddMacView's onChange(of:phase) will
                        // close the sheet. If we're still here
                        // the pair didn't succeed; let the user
                        // try again.
                    }
                } label: {
                    Group {
                        if isPairing {
                            HStack(spacing: 8) {
                                ProgressView().tint(.white)
                                Text("Requesting…")
                            }
                        } else {
                            Text("Send Pair Request")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isPairing)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var verificationText: String {
        if isSameICloud {
            return "This Mac is on the same iCloud account as this iPhone. The Mac will be notified and will accept the pairing automatically."
        }
        return "This Mac is on a different iCloud account. The Mac user will be asked to approve the pairing."
    }
}
