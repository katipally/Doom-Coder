// PairSheet.swift — DoomCoder Mac
// Modal sheet that shows the QR code + 6-character pairing code while the
// Mac waits for the iPhone to accept the iCloud share. Auto-dismisses
// when the coordinator reports the connection is .active.
//
// v2.8: shows a shimmer skeleton while the share is being created so
// the sheet never sits on a static spinner. The QR fades in with a
// spring animation when the URL arrives.

import SwiftUI
import DoomCoderCore
import AppKit

struct PairSheet: View {
    @ObservedObject private var coordinator = MacPairingCoordinator.shared
    @ObservedObject private var store = PairingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var qrAppeared: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Pair your iPhone")
                .font(.title2.weight(.semibold))
            Text("Scan the QR code with the iPhone DoomCoder app, or open the camera and point it at this window.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            qrPanel
            codePanel
            if case let .waitingForAcceptance(_, shareURL, _) = coordinator.phase {
                sendToIPhoneButton(shareURL: shareURL)
            }
            cancelButton
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 620)
        .onChange(of: coordinator.phase) { _, newPhase in
            if case .active = newPhase { dismiss() }
            if case .failed = newPhase { /* keep open so user sees error */ }
        }
    }

    @ViewBuilder
    private var qrPanel: some View {
        Group {
            switch coordinator.phase {
            case .waitingForAcceptance(_, let shareURL, _):
                if let nsImage = QRImageGenerator.image(for: shareURL, size: 240) {
                    Image(nsImage: nsImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                        )
                        .scaleEffect(qrAppeared ? 1.0 : 0.92)
                        .opacity(qrAppeared ? 1.0 : 0.0)
                        .symbolEffect(.bounce, value: qrAppeared)
                        .onAppear {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                                qrAppeared = true
                            }
                        }
                } else {
                    qrSkeleton
                }
            default:
                qrSkeleton
            }
        }
    }

    /// Shimmer skeleton shown while the share is being created.
    /// Mirrors the QR's 240x240 frame so the layout doesn't jump when
    /// the real QR arrives.
    private var qrSkeleton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
            ProgressView()
                .controlSize(.large)
        }
        .frame(width: 264, height: 264)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var codePanel: some View {
        if case let .waitingForAcceptance(code, _, expiresAt) = coordinator.phase {
            VStack(spacing: 4) {
                Text("Or type this code")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .tracking(4)
                Text("Expires \(expiresAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// v2.8: native AirDrop / share-sheet path as an alternative to QR.
    /// When the user is in the same room as their iPhone, AirDrop is
    /// ~2-3s end-to-end. QR remains as the fallback.
    @ViewBuilder
    private func sendToIPhoneButton(shareURL: URL) -> some View {
        VStack(spacing: 6) {
            HStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 0.5)
                Text("or")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 0.5)
            }
            .padding(.horizontal, 32)
            ShareLink(
                item: shareURL,
                subject: Text("Pair DoomCoder on this iPhone"),
                message: Text("Open this link in the DoomCoder app to pair."),
                preview: SharePreview("DoomCoder Pairing", icon: Image(systemName: "iphone.gen3"))
            ) {
                Label("Send to iPhone", systemImage: "iphone.and.arrow.forward")
                    .frame(maxWidth: 320)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") {
            coordinator.cancelPairing()
            dismiss()
        }
        .padding(.top, 4)
    }
}
