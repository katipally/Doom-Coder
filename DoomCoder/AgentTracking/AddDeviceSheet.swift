import SwiftUI
import AppKit
import CoreImage
import DoomCoderCore

// MARK: - AddDeviceSheet
//
// Sheet shown from Connections ▸ Add Device. Creates/fetches the Mac's
// zone-wide CKShare and presents a QR code + copy-link so an iPhone/iPad —
// on the SAME or a DIFFERENT iCloud account — can join. The link is a
// secret; participants can be revoked from the Connections list.
//
// macOS 26 design: native window toolbar (Cancel / Share menu) and a
// thin-material body. QR is wrapped in a concentric rounded rectangle
// frame. The button uses `.buttonStyle(.glassProminent)` for the new
// Liquid Glass aesthetic.

struct AddDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = MacShareCoordinator.shared
    @State private var copied = false
    @State private var showParticipants = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(24)
                .frame(minWidth: 360, idealWidth: 400, minHeight: 480)
        }
        .background(.regularMaterial)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .primaryAction) {
                if let url = coordinator.shareURL {
                    ShareLink(item: url) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    .help("Share the invite link via AirDrop, Messages, Mail, etc.")
                }
            }
        }
        .task { await coordinator.ensureShare() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "qrcode")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Device")
                        .font(.title2.bold())
                    Text("Pair an iPhone or iPad")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            qrBlock

            pairingPaths

            if !coordinator.participants.isEmpty {
                participantsDisclosure
            }

            Spacer(minLength: 0)
        }
    }

    /// Clarifies the two ways to pair so a new user knows the QR is only needed
    /// for a *different* Apple ID — same-iCloud devices appear on their own.
    @ViewBuilder
    private var pairingPaths: some View {
        VStack(alignment: .leading, spacing: 10) {
            pairingHint(
                symbol: "person.crop.rectangle.stack.fill",
                text: "**Same Apple ID?** No need to scan. Just open Doom Coder on your iPhone or iPad (signed in to the same iCloud) — this Mac appears automatically under Dashboard."
            )
            Divider().opacity(0.4)
            pairingHint(
                symbol: "qrcode",
                text: "**Different Apple ID?** Scan the code above with the device’s Camera, or send the invite link. Open it, then tap **Add Device ▸ Different iCloud**."
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func pairingHint(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(.init(text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var qrBlock: some View {
        if coordinator.isWorking && coordinator.shareURL == nil {
            VStack(spacing: 10) {
                ProgressView()
                Text("Preparing invite…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if let url = coordinator.shareURL {
            VStack(spacing: 12) {
                if let qr = Self.qrImage(from: url.absoluteString) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                        .accessibilityLabel("Pairing QR code")
                }
                Text("On your iPhone or iPad: Dashboard ▸ Add Device ▸ Different iCloud ▸ Scan QR Code. Or send the link below. Works even if the device uses a different iCloud account.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(url.absoluteString, forType: .string)
                    HapticsTap()
                    withAnimation(DCAnim.micro) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(DCAnim.micro) { copied = false }
                    }
                } label: {
                    Label(copied ? "Link Copied" : "Copy Invite Link",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(coordinator.lastError ?? "Couldn't prepare the invite.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await coordinator.ensureShare() } }
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    @ViewBuilder
    private var participantsDisclosure: some View {
        DisclosureGroup(isExpanded: $showParticipants) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(coordinator.participants) { p in
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(p.displayName)
                            .font(.callout)
                        let status = p.acceptanceStatus
                        if !status.isEmpty {
                            Text(status.capitalized)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Participants (\(coordinator.participants.count))", systemImage: "person.2")
                .font(.callout.weight(.medium))
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Generates a crisp QR code NSImage for `string` using CoreImage.
    static func qrImage(from string: String) -> NSImage? {
        let data = Data(string.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width,
                                                 height: scaled.extent.height))
    }
}

/// Tiny wrapper for system tap feedback. NSE-only haptics not used here;
/// we rely on the system sound + button visual change. Kept here as a
/// private helper scoped to this file.
private func HapticsTap() {
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
}
