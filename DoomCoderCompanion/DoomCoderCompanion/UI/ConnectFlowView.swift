// ConnectFlowView.swift — DoomCoder Companion
// "Add Device" sheet with two clear sections:
//   • Same iCloud      — auto-discovered Macs on your iCloud → tap to connect.
//   • Different iCloud  — scan a QR code or paste the invite link (e.g. a work
//                         laptop on another Apple ID).
// Reused from the Dashboard switcher ("Add Device…") and Settings for a
// consistent UX. After connecting we optionally ask for notification permission.

import SwiftUI
import CloudKit
import UserNotifications
import AVFoundation
import UIKit
import DoomCoderCore

struct ConnectFlowView: View {
    let onFinished: () -> Void

    enum Step {
        case checkingiCloud
        case icloudNeeded
        case chooser
        case connecting
        case connected
        case notifications
    }

    @State private var step: Step = .checkingiCloud
    @State private var macStore = MacStatusStore.shared
    @State private var showScanner = false
    @State private var pairingError: String?
    @State private var pastedURL = ""
    @State private var isLooking = false
    @Environment(\.dismiss) private var dismiss

    /// "online" if a Mac's heartbeat is recent.
    private func isOnline(_ mac: MacStatusRecord) -> Bool {
        Date().timeIntervalSince(mac.lastSeen) < 600
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    content
                }
                .padding(20)
            }
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { finish() }
                }
            }
            .task { await begin() }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    showScanner = false
                    Task { await handleURLString(code) }
                } onCancel: {
                    showScanner = false
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .checkingiCloud:
            phase(symbol: "icloud", title: "Checking iCloud…",
                  detail: "DoomCoder uses iCloud to sync with your Mac.",
                  showSpinner: true)

        case .icloudNeeded:
            phase(symbol: "icloud.slash", title: "Sign in to iCloud",
                  detail: "To connect a Mac on your own iCloud, sign in to iCloud in the Settings app, then try again. (A Mac on a different iCloud can still be added by QR or link.)")
            VStack(spacing: 12) {
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { Task { await begin() } }
                Button("Continue anyway") { step = .chooser }
                    .foregroundStyle(.secondary)
            }

        case .chooser:
            chooser

        case .connecting:
            phase(symbol: "antenna.radiowaves.left.and.right", title: "Connecting…",
                  detail: "Joining your Mac and syncing for the first time.",
                  showSpinner: true)

        case .connected:
            phase(symbol: "checkmark.circle.fill", title: "Connected",
                  detail: "You're connected to \(macStore.primary?.name ?? "your Mac").")
                .onAppear {
                    Haptics.success()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        await advanceAfterConnect()
                    }
                }

        case .notifications:
            phase(symbol: "bell.badge", title: "Get notified",
                  detail: "DoomCoder can alert you when an agent on your Mac needs your attention — for example, when it's waiting for approval. No marketing, ever. This is optional.")
            VStack(spacing: 12) {
                Button("Enable Notifications") { Task { await requestNotifications() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Not Now") { finish() }
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Chooser (two sections)

    private var chooser: some View {
        VStack(spacing: 20) {
            if let pairingError {
                Label(pairingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            sameICloudSection
            differentICloudSection
        }
    }

    private var sameICloudSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Same iCloud", systemImage: "person.icloud")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refreshSameICloud() }
                } label: {
                    if isLooking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .accessibilityLabel("Look for Macs again")
            }

            let macs = Array(macStore.byMacId.values).sorted { $0.lastSeen > $1.lastSeen }
            if macs.isEmpty {
                Text(isLooking
                     ? "Looking for Macs on your iCloud…"
                     : "No Macs found on your iCloud yet. Open DoomCoder on your Mac and make sure it's signed in to the same iCloud account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(macs, id: \.macId) { mac in
                    macRow(mac)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func macRow(_ mac: MacStatusRecord) -> some View {
        let isActive = mac.macId == macStore.primary?.macId
        return Button {
            select(mac.macId)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name).font(.callout.weight(.medium))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isOnline(mac) ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(isOnline(mac) ? "Online" : "Last seen \(mac.lastSeen, style: .relative) ago")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isActive {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                } else {
                    Text("Connect").font(.subheadline.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private var differentICloudSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Different iCloud", systemImage: "qrcode")
                .font(.headline)
            Text("Connect a Mac on another Apple ID (e.g. a work laptop). On that Mac: DoomCoder ▸ Connections ▸ Add Device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                pairingError = nil
                showScanner = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                if let s = UIPasteboard.general.string { Task { await handleURLString(s) } }
                else { pairingError = "Clipboard is empty. Copy the invite link on your Mac first." }
            } label: {
                Label("Paste Invite Link", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            HStack(spacing: 8) {
                TextField("or paste the link here", text: $pastedURL)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await handleURLString(pastedURL) } }
                Button("Go") { Task { await handleURLString(pastedURL) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func phase(symbol: String, title: String, detail: String, showSpinner: Bool = false) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if showSpinner { ProgressView().padding(.top, 4) }
        }
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Flow logic

    private func begin() async {
        step = .checkingiCloud
        let available = await isiCloudAvailable()
        guard available else { step = .icloudNeeded; return }
        step = .chooser
        await refreshSameICloud()
    }

    /// Pulls the private database so same-iCloud Macs appear in the list. Does
    /// NOT auto-connect — the user picks from the two sections.
    private func refreshSameICloud() async {
        isLooking = true
        defer { isLooking = false }
        await CompanionSyncEngine.shared.forceFetchAll()
        for _ in 0..<2 where macStore.byMacId.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            await CompanionSyncEngine.shared.fetchChanges()
        }
    }

    private func select(_ macId: String) {
        macStore.setPrimary(macId)
        step = .connected
    }

    /// Validates an iCloud share URL string and accepts it (QR or pasted link).
    private func handleURLString(_ raw: String) async {
        pairingError = nil
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              (url.scheme == "https" || url.scheme == "http"),
              (url.host?.contains("icloud.com") == true) else {
            pairingError = "That doesn't look like a DoomCoder invite link. Copy the link (or scan the QR) shown on your Mac under Connections ▸ Add Device."
            step = .chooser
            return
        }
        step = .connecting
        let ok = await CompanionSyncEngine.shared.acceptShare(at: url)
        if ok {
            for _ in 0..<5 where macStore.byMacId.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                await CompanionSyncEngine.shared.fetchChanges()
            }
        }
        if ok, let newest = macStore.byMacId.values.sorted(by: { $0.lastSeen > $1.lastSeen }).first {
            select(newest.macId)
        } else {
            pairingError = ok
                ? "Connected, but your Mac hasn't synced yet. Make sure DoomCoder is open on your Mac, then try again."
                : "Couldn't connect with that invite. Make sure the QR/link on your Mac is current, then try again."
            step = .chooser
        }
    }

    private func advanceAfterConnect() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            step = .notifications
        } else {
            finish()
        }
    }

    private func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        finish()
    }

    private func isiCloudAvailable() async -> Bool {
        let status = try? await CKContainer(identifier: CloudKitConstants.containerIdentifier).accountStatus()
        return status == .available
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func finish() {
        onFinished()
        dismiss()
    }
}

// MARK: - QR scanner

/// Lightweight AVFoundation QR scanner presented during pairing. Reports the
/// first decoded string via `onScan`. Requires `NSCameraUsageDescription`.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.coordinator = context.coordinator
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        private var didScan = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        // Delivered on the main queue (we set `queue: .main` on the output), so
        // assumeIsolated is safe and lets us call the @MainActor onScan closure.
        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                        didOutput metadataObjects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            // Extract the Sendable String in the nonisolated context, then hop —
            // only the String crosses the isolation boundary.
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr,
                  let value = obj.stringValue else { return }
            MainActor.assumeIsolated {
                guard !didScan else { return }
                didScan = true
                onScan(value)
            }
        }
    }

    /// Confines the non-Sendable AVCaptureSession for cross-queue start/stop.
    private struct SessionBox: @unchecked Sendable {
        let session: AVCaptureSession
        func start() { if !session.isRunning { session.startRunning() } }
        func stop()  { if session.isRunning { session.stopRunning() } }
    }

    final class ScannerController: UIViewController {
        weak var coordinator: Coordinator?
        var onCancel: (() -> Void)?
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "doomcoder.qr.session")
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configureSession()

            let cancel = UIButton(type: .system)
            cancel.setTitle("Cancel", for: .normal)
            cancel.setTitleColor(.white, for: .normal)
            cancel.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
            cancel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cancel)
            NSLayoutConstraint.activate([
                cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
                cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
            ])

            let hint = UILabel()
            hint.text = "Scan the QR code on your Mac\n(Connections ▸ Add Device)"
            hint.numberOfLines = 0
            hint.textAlignment = .center
            hint.textColor = .white
            hint.font = .preferredFont(forTextStyle: .callout)
            hint.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
                hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
            ])
        }

        private func configureSession() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.layer.bounds
            view.layer.insertSublayer(layer, at: 0)
            self.preview = layer
            let box = SessionBox(session: session)
            sessionQueue.async { box.start() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.layer.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let box = SessionBox(session: session)
            sessionQueue.async { box.stop() }
        }
    }
}
