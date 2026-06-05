// PendingPairRequestSheet.swift — DoomCoder Mac
// v5.1: the sheet the Mac user sees when an iOS device sends a
// CSC{pending,origin:ios} from the "Same iCloud" discoverable
// list. Allow / Deny buttons. The sheet shows the iOS device's
// verification state — "On the same iCloud" / "On a different
// iCloud" — based on comparing the iOS-supplied iosUserRecordID
// to the Mac's own userRecordID().

import SwiftUI
import CloudKit
import DoomCoderCore

struct PendingPairRequestSheet: View {
    let request: PendingPairRequestQueue.Request
    let onAllow: () async -> Void
    let onDeny: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isWorking: Bool = false
    @State private var sameICloud: Bool? = nil
    @State private var macUserRecordName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair with \(iosDeviceDisplayName)?")
                        .font(.title2.weight(.semibold))
                    Text("iPhone wants to share agents and notifications with this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            verificationSection

            Spacer()
            HStack {
                Button("Deny", role: .destructive) {
                    Task {
                        isWorking = true
                        await onDeny()
                        isWorking = false
                        dismiss()
                    }
                }
                .controlSize(.large)
                .disabled(isWorking)

                Spacer()

                Button {
                    Task {
                        isWorking = true
                        await onAllow()
                        isWorking = false
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        }
                        Text("Allow")
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 320)
        .task {
            // v5.1: verify same-iCloud authoritatively via
            // container.userRecordID(). Only run this once.
            if sameICloud == nil {
                do {
                    let id = try await CKContainer.default().userRecordID().recordName
                    macUserRecordName = id
                    if let ios = request.iosUserRecordID, !ios.isEmpty {
                        sameICloud = (id == ios)
                    } else {
                        // iOS app couldn't capture its own user
                        // record ID (probably not signed in to
                        // iCloud on the iOS side). Show a
                        // neutral "verification unavailable"
                        // state and let the user decide.
                        sameICloud = nil
                    }
                } catch {
                    sameICloud = nil
                }
            }
        }
    }

    @ViewBuilder
    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sameICloud == true {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("On the same iCloud account")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                }
                if let mac = macUserRecordName, let ios = request.iosUserRecordID {
                    Text("Mac: \(mac)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("iPhone: \(ios)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } else if sameICloud == false {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.crop.square.stack")
                        .foregroundStyle(.orange)
                    Text("On a different iCloud account")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Text("Pairing will share the iPhone's agents and notifications with this Mac. You can revoke the connection at any time from the Connections tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                    Text("Couldn't verify iCloud account")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("The iPhone may not be signed in to iCloud, or we couldn't read its user record. Pairing will still work, but you'll be connecting across accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Best-effort display name for the iOS device while we wait
    /// for the first heart-beat. Falls back to a generic
    /// "iPhone" with the device id suffix.
    private var iosDeviceDisplayName: String {
        "iPhone"
    }
}
