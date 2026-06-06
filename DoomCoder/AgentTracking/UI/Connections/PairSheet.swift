// PairSheet.swift — DoomCoder Mac
// v5 rewrite: single-column stepper layout per plan §6.1. The
// previous v2.9 layout tried to fit a 240×240 QR card + code +
// instructions + two link buttons in two columns at 580×420 and
// clipped the link buttons on small windows. The new layout
// uses one centered 540-wide column with the QR + code on top
// and the link options below, and a status pill in the header
// that animates as the iPhone accepts.
//
// State machine:
//   • creating   → full-width spinner card with helper copy
//   • waiting    → QR + code + link buttons + "Waiting for iPhone" pill
//   • accepted   → green pill, checkmark animation, auto-dismiss in 1.2s
//   • failed     → red pill, error card with Try Again
//   • idle       → blank (cancelled)

import SwiftUI
import DoomCoderCore
import AppKit
import CloudKit

struct PairSheet: View {
    @ObservedObject private var coordinator = MacPairingCoordinator.shared
    @ObservedObject private var deviceSub = DiscoverableDeviceSubscription.shared
    @ObservedObject private var store = PairingStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var qrAppeared: Bool = false

    enum Route: String, CaseIterable, Identifiable {
        case sameICloud = "Same iCloud"
        case differentICloud = "Different iCloud"
        var id: String { rawValue }
    }
    @State private var route: Route = .sameICloud

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Picker("", selection: $route) {
                ForEach(Route.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                switch route {
                case .sameICloud:      sameICloudTab
                case .differentICloud: differentICloudTab
                }
            }
        }
        .frame(minWidth: 540, idealWidth: 560, maxWidth: 600, minHeight: 580, idealHeight: 620, maxHeight: 720)
        .task {
            await deviceSub.start()
            // Default tab is Same iCloud — publish its code/QR right away.
            await coordinator.startSameICloudCodeIfNeeded()
            // Keep the Same-iCloud picker live while the sheet is open by
            // pulling fresh PeerStatus (cancelled automatically on dismiss).
            while !Task.isCancelled {
                CloudKitPusher.shared.fetchNow()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .onChange(of: route) { _, newRoute in
            if newRoute == .sameICloud {
                // Ensure the same-iCloud code/QR is live when the user returns.
                Task { await coordinator.startSameICloudCodeIfNeeded() }
            }
            // Lazily create the CKShare only when the user actually wants the
            // cross-account (QR/code/link) flow.
            if newRoute == .differentICloud, case .idle = coordinator.phase {
                Task { await coordinator.startPairing() }
            }
        }
        .onChange(of: coordinator.phase) { _, newPhase in
            if case .active = newPhase {
                Task {
                    try? await Task.sleep(for: .milliseconds(1200))
                    dismiss()
                }
            }
        }
    }

    // MARK: - Different iCloud tab (QR / code / link)

    private var differentICloudTab: some View {
        VStack(spacing: 18) {
            qrCard
            if case .waitingForAcceptance(_, _, let expiresAt) = coordinator.phase {
                codePanel(expiresAt: expiresAt)
            }
            if case .waitingForAcceptance(_, let shareURL, _) = coordinator.phase {
                linkButtons(shareURL: shareURL)
            }
            if case .creatingShare = coordinator.phase {
                creatingCopy
            }
            footerNote
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Same iCloud tab (AirDrop-style picker)

    private var sameICloudTab: some View {
        VStack(spacing: 16) {
            if deviceSub.devices.isEmpty {
                sameICloudEmptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 18)], spacing: 18) {
                    ForEach(deviceSub.devices) { device in
                        deviceTile(device)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            Text("Pick an iPhone on your iCloud account. It will get a request to accept on its screen.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            sameICloudCodeSection
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }

    /// Alternative to the picker: a QR + 6-char code + link the iPhone can scan,
    /// type, or open to connect on the same iCloud account.
    @ViewBuilder private var sameICloudCodeSection: some View {
        if let scc = coordinator.sameICloudCode {
            VStack(spacing: 12) {
                Divider().padding(.horizontal, 24).padding(.top, 4)
                Text("Or pair with a code / QR")
                    .font(.subheadline.weight(.medium))
                if let img = QRImageGenerator.image(for: scc.payloadURL, size: 200) {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                        )
                }
                HStack(spacing: 10) {
                    Text(scc.code)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .tracking(4)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(scc.code, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy code")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(scc.payloadURL.absoluteString, forType: .string)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Text("On iPhone: scan in Add Device ▸ Scan, or type the code in Add Device ▸ Type.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .padding(.top, 4)
        }
    }

    private var sameICloudEmptyState: some View {
        VStack(spacing: 12) {
            if deviceSub.isLoading {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: "iphone.gen3.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
            Text("No iPhones found on this iCloud")
                .font(.headline)
            Text("Open DoomCoder on your iPhone (signed in to the same Apple ID) and it will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                Task { await deviceSub.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func deviceTile(_ device: DiscoverableDeviceRecord) -> some View {
        let conn = store.connections.first(where: { $0.iosDeviceId == device.iosDeviceId })
        let state: DerivedDeviceState? = conn.map { IosDeviceProfileCache.shared.derivedState(for: $0) }
        return Button {
            Task { await coordinator.requestSameICloudPair(device: device) }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(.regularMaterial)
                        .frame(width: 76, height: 76)
                        .overlay(Circle().strokeBorder(tileTint(state).opacity(0.5), lineWidth: 2))
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 32))
                        .foregroundStyle(tileTint(state))
                }
                Text(device.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(tileSubtitle(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // v7: always tappable. Tapping a connected device re-asserts the
        // connection (idempotent) so a desynced iPhone reconnects.
    }

    private func tileTint(_ state: DerivedDeviceState?) -> Color {
        switch state {
        case .active:  return .green
        case .pending: return .blue
        default:       return .accentColor
        }
    }

    private func tileSubtitle(_ state: DerivedDeviceState?) -> String {
        switch state {
        case .active:  return "Connected · tap to re-sync"
        case .pending: return "Connecting…"
        case .offline: return "Paired · offline"
        default:       return "Tap to pair"
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            Text("Pair a Device")
                .font(.title2.weight(.semibold))
            statusPill
            Spacer()
            Button("Cancel") {
                coordinator.cancelPairing()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch coordinator.phase {
        case .idle:
            EmptyView()
        case .creatingShare:
            statusPillContent(symbol: "icloud.and.arrow.up", text: "Preparing…", color: .secondary)
        case .waitingForAcceptance:
            HStack(spacing: 6) {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
                    .modifier(PulseModifier())
                Text("Waiting for iPhone")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.blue.opacity(0.12), in: Capsule())
        case .active:
            statusPillContent(symbol: "checkmark.circle.fill", text: "Paired", color: .green)
        case .failed:
            statusPillContent(symbol: "exclamationmark.triangle.fill", text: "Failed", color: .red)
        }
    }

    private func statusPillContent(symbol: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
                .font(.callout.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - QR card

    @ViewBuilder
    private var qrCard: some View {
        Group {
            switch coordinator.phase {
            case .waitingForAcceptance(_, let shareURL, _):
                if let nsImage = QRImageGenerator.image(for: shareURL, size: 280) {
                    qrImage(nsImage: nsImage)
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

    private func qrImage(nsImage: NSImage) -> some View {
        Image(nsImage: nsImage)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 280, height: 280)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
            .scaleEffect(qrAppeared ? 1.0 : 0.94)
            .opacity(qrAppeared ? 1.0 : 0.0)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                    qrAppeared = true
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
                .frame(maxWidth: 320)
            Button {
                qrAppeared = false
                Task { await coordinator.startPairing() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(width: 320, height: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var qrSkeleton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text("Preparing pairing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 320, height: 320)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    // MARK: - Code panel

    private func codePanel(expiresAt: Date) -> some View {
        Group {
            if case let .waitingForAcceptance(code, _, _) = coordinator.phase {
                VStack(spacing: 4) {
                    Text("Or type this 6-character code")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text(code)
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .tracking(4)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy code")
                    }
                    Text("Expires \(expiresAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Link buttons

    private func linkButtons(shareURL: URL) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                copyLinkButton(shareURL: shareURL)
                shareButton(shareURL: shareURL)
            }
        }
    }

    private func copyLinkButton(shareURL: URL) -> some View {
        Button {
            if let deepLink = Self.deepLink(for: shareURL) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(deepLink.absoluteString, forType: .string)
            }
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity)
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
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: - Footer

    private var creatingCopy: some View {
        Text("First-time CloudKit schema warm-up can take up to 30 seconds.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    private var footerNote: some View {
        Text("The pairing code expires in 10 minutes. You can also share the link via AirDrop or Messages.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 6)
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

// MARK: - Pulse animation modifier for the waiting pill

private struct PulseModifier: ViewModifier {
    @State private var pulse: Bool = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(pulse ? 1.3 : 1.0)
            .opacity(pulse ? 0.0 : 1.0)
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: false),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}
