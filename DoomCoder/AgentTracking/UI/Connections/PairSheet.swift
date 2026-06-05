// PairSheet.swift — DoomCoder Mac
// Two-column pairing sheet. Left: QR code + 6-char pairing code.
// Right (separated by an "or" divider): Copy Link, Send to iPhone, Cancel.
// The layout keeps all the information on-screen at once without scrolling.

import SwiftUI
import DoomCoderCore
import AppKit
import CloudKit

struct PairSheet: View {
    @ObservedObject private var coordinator = MacPairingCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var qrAppeared: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            HStack(alignment: .center, spacing: 0) {
                leftColumn
                orDivider
                rightColumn
            }
        }
        .frame(minWidth: 580, minHeight: 420)
        .onChange(of: coordinator.phase) { _, newPhase in
            if case .active = newPhase { dismiss() }
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            Text("Pair a Device")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("Cancel") {
                coordinator.cancelPairing()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    // MARK: - Left column: QR + code

    private var leftColumn: some View {
        VStack(spacing: 14) {
            if case .failed = coordinator.phase {
                // error state — no description
            } else {
                Text("Scan with the DoomCoder app on iPhone or iPad.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: 240)
            }
            qrPanel
            codePanel
        }
        .frame(minWidth: 280, maxWidth: 320)
        .padding(28)
    }

    @ViewBuilder
    private var qrPanel: some View {
        Group {
            switch coordinator.phase {
            case .waitingForAcceptance(_, let shareURL, _):
                if let nsImage = QRImageGenerator.image(for: shareURL, size: 220) {
                    Image(nsImage: nsImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                        )
                        .scaleEffect(qrAppeared ? 1.0 : 0.92)
                        .opacity(qrAppeared ? 1.0 : 0.0)
                        .onAppear {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                                qrAppeared = true
                            }
                        }
                } else {
                    qrSkeleton
                }
            case .failed(let err):
                errorPanel(err)
            default:
                qrSkeleton
            }
        }
    }

    private func errorPanel(_ err: ConnectionError) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(err.userMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(maxWidth: 240)
            Button {
                qrAppeared = false
                Task { await coordinator.startPairing() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: 180)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(width: 240, height: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var qrSkeleton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
            ProgressView()
                .controlSize(.large)
        }
        .frame(width: 240, height: 240)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var codePanel: some View {
        if case let .waitingForAcceptance(code, _, expiresAt) = coordinator.phase {
            VStack(spacing: 3) {
                Text("Or type this code")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .tracking(4)
                Text("Expires \(expiresAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - "or" divider

    private var orDivider: some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 0.5)
            Text("or")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 0.5)
        }
        .frame(width: 40)
        .padding(.vertical, 28)
    }

    // MARK: - Right column: link options

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            if case let .waitingForAcceptance(_, shareURL, _) = coordinator.phase {
                copyLinkButton(shareURL: shareURL)
                shareButton(shareURL: shareURL)
            } else {
                // Placeholder while QR is loading
                VStack(alignment: .leading, spacing: 16) {
                    optionPlaceholder
                    optionPlaceholder
                }
            }
            Spacer()
            Text("The QR code expires in 10 minutes.\nYou can also share the link via AirDrop or Messages.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 220, maxWidth: 280)
        .padding(28)
    }

    private func copyLinkButton(shareURL: URL) -> some View {
        Button {
            if let deepLink = Self.deepLink(for: shareURL) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(deepLink.absoluteString, forType: .string)
            }
        } label: {
            Label("Copy Pairing Link", systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help("Paste this link in Messages and tap it on iPhone to pair without scanning.")
    }

    private func shareButton(shareURL: URL) -> some View {
        ShareLink(
            item: shareURL,
            subject: Text("Pair DoomCoder"),
            message: Text("Open this link in the DoomCoder app on iPhone to pair."),
            preview: SharePreview("DoomCoder Pairing", icon: Image(systemName: "iphone.gen3"))
        ) {
            Label("Send to iPhone", systemImage: "iphone.and.arrow.forward")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var optionPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.08))
            .frame(height: 36)
    }

    // MARK: - Deep link factory

    static func deepLink(for shareURL: URL) -> URL? {
        var c = URLComponents()
        c.scheme = "doomcoder"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "ckShareURL", value: shareURL.absoluteString),
            URLQueryItem(name: "container", value: CloudKitConstants.containerIdentifier)
        ]
        return c.url
    }
}
