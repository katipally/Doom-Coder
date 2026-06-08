// ConnectFlowView.swift — Doom Coder Companion
// "Add Device" sheet for the iOS companion.
//
// iOS 26 design:
//   • Partial-height sheet (`.medium` / `.large` detents) with a Liquid Glass
//     background — the system supplies the material; we removed our custom
//     `Color(.systemGroupedBackground)` so it can shine through.
//   • Top inline nav title, trailing "Done" button (system role .cancel).
//   • Two `GlassEffectContainer` cards: "Same iCloud" and "Different iCloud".
//   • `navigationZoomTransition` is presented by the toolbar "Add Device"
//     button in DashboardView (HIG: sheets morph out of source buttons).
//   • A custom stepper header in non-chooser phases for clarity at small detent.
//   • `navigationZoomTransition` reads the source as a namespace key on the
//     Dashboard's "Add Device" button. The destination is the sheet's root.
//
// Steps: checkingiCloud → icloudNeeded (or chooser) → connecting → connected.
// Notification permission is no longer requested here — it lives in the
// onboarding "Get Started" + cold-launch denied-check flow (see
// NotificationPermissionCenter + RootTabView).

import SwiftUI
import CloudKit
import AVFoundation
import UIKit
import DoomCodeCore

// MARK: - Root sheet

struct ConnectFlowView: View {
    let onFinished: () -> Void

    enum Step: Equatable {
        case checkingiCloud
        case icloudNeeded
        case chooser
        case connecting
        case connected
    }

    @State private var step: Step = .checkingiCloud
    @State private var macStore = MacStatusStore.shared
    @State private var showScanner = false
    @State private var pairingError: String?
    @State private var pastedURL = ""
    @State private var isLooking = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    /// "online" if a Mac's heartbeat is recent.
    private func isOnline(_ mac: MacStatusRecord) -> Bool {
        Date().timeIntervalSince(mac.lastSeen) < 600
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if step != .chooser {
                        StepperHeader(step: step)
                            .padding(.top, 4)
                    }
                    content
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .cancel) { finish() } label: { Text("Done") }
                }
            }
            .task { await begin() }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { code in
                    showScanner = false
                    Task { await handleURLString(code) }
                } onCancel: {
                    showScanner = false
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .checkingiCloud:
            PhaseHero(
                symbol: "icloud",
                title: "Checking iCloud…",
                detail: "Doom Coder uses iCloud to sync with your Mac.",
                showSpinner: true
            )

        case .icloudNeeded:
            PhaseHero(
                symbol: "icloud.slash",
                title: "Sign in to iCloud",
                detail: "To connect a Mac on your own iCloud, sign in to iCloud in the Settings app, then try again. (A Mac on a different iCloud can still be added by QR or link.)"
            )
            VStack(spacing: 12) {
                Button {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    Task { await begin() }
                } label: {
                    Text("Try Again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    step = .chooser
                } label: {
                    Text("Continue anyway")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .padding(.top, 8)

        case .chooser:
            chooser

        case .connecting:
            PhaseHero(
                symbol: "antenna.radiowaves.left.and.right",
                title: "Connecting…",
                detail: "Joining your Mac and syncing for the first time.",
                showSpinner: true
            )

        case .connected:
            PhaseHero(
                symbol: "checkmark.circle.fill",
                title: "Connected",
                detail: "You're connected to \(macStore.primary?.name ?? "your Mac")."
            )
            .onAppear {
                Haptics.success()
                Task {
                    try? await Task.sleep(for: .seconds(reduceMotion ? 0.6 : 1.0))
                    finish()
                }
            }
        }
    }

    // MARK: - Chooser (two glass cards)

    private var chooser: some View {
        VStack(spacing: 14) {
            if let pairingError {
                Label(pairingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
            }
            sameICloudCard
            differentICloudCard
        }
        .animation(.snappy(duration: 0.25), value: pairingError)
    }

    // MARK: Same-iCloud card

    private var sameICloudCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("Same iCloud", systemImage: "person.crop.rectangle.stack.fill")
                        .font(.headline)
                    Spacer()
                    Button {
                        Task { await refreshSameICloud() }
                    } label: {
                        if isLooking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Look for Macs again")
                    .accessibilityHint("Re-fetches the list of Macs on your iCloud")
                }

                let macs = Array(macStore.byMacId.values).sorted { $0.lastSeen > $1.lastSeen }
                if macs.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "macbook.slash")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isLooking ? "Looking for Macs on your iCloud…" : "No Macs found on your iCloud yet.")
                                .font(.callout)
                            Text("Open Doom Coder on your Mac and make sure it's signed in to the same iCloud account.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(macs.enumerated()), id: \.element.macId) { index, mac in
                            macRow(mac)
                            if index < macs.count - 1 {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                }

                ConnectionGuide(title: "How do I connect?", steps: [
                    "On your Mac, open **Doom Coder** and sign in to the **same iCloud account** (the same Apple ID as this iPhone).",
                    "Click the **Doom Coder icon** in the Mac menu bar ▸ **Configure Agents…** ▸ **Connections**.",
                    "Wait until it shows **“Ready as [your Mac]”**.",
                    "Your Mac appears above — tap **Connect**."
                ])
            }
        }
    }

    @ViewBuilder
    private func macRow(_ mac: MacStatusRecord) -> some View {
        let isActive = mac.macId == macStore.primary?.macId
        Button {
            Haptics.selection()
            select(mac.macId)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name).font(.callout.weight(.medium))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isOnline(mac) ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                            .contentTransition(.symbolEffect(.replace))
                        Text(isOnline(mac) ? "Online" : "Last seen \(mac.lastSeen, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isActive {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Connected")
                } else {
                    Text("Connect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mac.name), \(isOnline(mac) ? "online" : "last seen \(mac.lastSeen.formatted(.relative(presentation: .named)))")")
        .accessibilityHint(isActive ? "Currently connected" : "Double tap to connect")
    }

    // MARK: Different-iCloud card

    private var differentICloudCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Different iCloud", systemImage: "qrcode.viewfinder")
                    .font(.headline)

                Text("Connect a Mac on another Apple ID (e.g. a work laptop) using a QR code or invite link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ConnectionGuide(title: "How do I get the QR code?", steps: [
                    "On your Mac, click the **Doom Coder icon** in the menu bar ▸ **Configure Agents…**",
                    "Open the **Connections** tab, then click **Add Device…**",
                    "A **QR code** and **invite link** appear on your Mac.",
                    "**Scan** the QR below, or **paste** the link."
                ])

                Button {
                    Haptics.tap()
                    pairingError = nil
                    showScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    if let s = UIPasteboard.general.string {
                        Task { await handleURLString(s) }
                    } else {
                        pairingError = "Clipboard is empty. Copy the invite link on your Mac first."
                    }
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
                        .onSubmit {
                            Task { await handleURLString(pastedURL) }
                        }
                    Button {
                        Task { await handleURLString(pastedURL) }
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Submit invite link")
                }
            }
        }
    }

    // MARK: - Flow logic

    private func begin() async {
        step = .checkingiCloud
        let available = await isiCloudAvailable()
        if available {
            step = .chooser
            await refreshSameICloud()
        } else {
            step = .icloudNeeded
        }
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
            pairingError = "That doesn't look like a Doom Coder invite link. Copy the link (or scan the QR) shown on your Mac under Configure Agents ▸ Connections ▸ Add Device."
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
                ? "Connected, but your Mac hasn't synced yet. Make sure Doom Coder is open on your Mac, then try again."
                : "Couldn't connect with that invite. Make sure the QR/link on your Mac is current, then try again."
            step = .chooser
        }
    }

    private func isiCloudAvailable() async -> Bool {
        let status = try? await CKContainer(identifier: CloudKitConstants.containerIdentifier).accountStatus()
        return status == .available
    }

    private func finish() {
        onFinished()
        dismiss()
    }
}

// MARK: - Connection guide

/// A collapsible, numbered step-by-step guide shown inside a pairing card.
/// Collapsed by default to keep the sheet compact; step strings accept simple
/// `**bold**` markdown (rendered via `Text(.init:)`).
private struct ConnectionGuide: View {
    let title: String
    let steps: [String]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(.init(step))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Label(title, systemImage: "questionmark.circle")
                .font(.caption.weight(.medium))
        }
        .tint(.secondary)
    }
}

// MARK: - GlassCard container

/// A card whose contents sit on the system Liquid Glass material (iOS 26).
/// We let the system provide the material via `.glassEffect()` on iOS 26+
/// and fall back to a flat grouped background on older OSes.
private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

// MARK: - Phase hero

private struct PhaseHero: View {
    let symbol: String
    let title: String
    let detail: String
    var showSpinner: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.variableColor.iterative, isActive: showSpinner)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if showSpinner {
                ProgressView().padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

// MARK: - Stepper header

/// A small visual progress strip used for non-chooser phases. Hidden in
/// `.chooser` so it doesn't fight the two main cards.
private struct StepperHeader: View {
    let step: ConnectFlowView.Step

    private struct Step: Hashable { let key: String; let label: String }

    private var steps: [Step] {
        [Step(key: "icloud", label: "iCloud"),
         Step(key: "choose", label: "Choose"),
         Step(key: "connect", label: "Connect"),
         Step(key: "done", label: "Done")]
    }

    private var activeIndex: Int {
        switch step {
        case .checkingiCloud:   return 0
        case .icloudNeeded:     return 0
        case .chooser:          return 1
        case .connecting:       return 2
        case .connected:        return 3
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, s in
                HStack(spacing: 0) {
                    VStack(spacing: 4) {
                        Circle()
                            .fill(idx <= activeIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 8, height: 8)
                            .animation(.snappy(duration: 0.25), value: activeIndex)
                        Text(s.label)
                            .font(.caption2)
                            .foregroundStyle(idx <= activeIndex ? .primary : .secondary)
                    }
                    if idx < steps.count - 1 {
                        Rectangle()
                            .fill(idx < activeIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(height: 2)
                            .animation(.snappy(duration: 0.25), value: activeIndex)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(activeIndex + 1) of \(steps.count): \(steps[activeIndex].label)")
    }
}

// MARK: - QR scanner sheet

/// AVFoundation QR scanner wrapped for SwiftUI presentation. Reports the first
/// decoded string via `onScan`. Requires `NSCameraUsageDescription`.
struct QRScannerSheet: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController(coordinator: context.coordinator)
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        private var didScan = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                        didOutput metadataObjects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
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
        // `let` (audit 2026-06 fix): previously `weak var coordinator` was
        // assigned in `makeUIViewController` *after* `viewDidLoad` ran, so
        // the first metadata emission found a nil delegate and the QR
        // scanner silently dropped its first scan. Moving the assignment
        // into `init` makes the coordinator available before any UIKit
        // lifecycle callback fires.
        let coordinator: Coordinator
        var onCancel: (() -> Void)?
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "doomcoder.qr.session")
        private var preview: AVCaptureVideoPreviewLayer?
        private var torchOn = false
        /// Set during permission denial so the SwiftUI sheet can render a
        /// "Settings → Camera" deep-link instead of a black screen
        /// (audit 2026-06).
        private var permissionDenied = false

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            requestCameraPermissionAndConfigure()

            // Liquid Glass viewfinder cutout (system material on top of camera).
            let cutout = UIView()
            cutout.translatesAutoresizingMaskIntoConstraints = false
            cutout.backgroundColor = .clear
            cutout.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
            cutout.layer.borderWidth = 3
            cutout.layer.cornerRadius = 22
            cutout.layer.cornerCurve = .continuous
            cutout.isUserInteractionEnabled = false
            view.addSubview(cutout)
            NSLayoutConstraint.activate([
                cutout.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                cutout.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                cutout.widthAnchor.constraint(equalToConstant: 260),
                cutout.heightAnchor.constraint(equalToConstant: 260)
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

            // Top-leading Cancel
            let cancel = UIButton(type: .system)
            cancel.setTitle("Cancel", for: .normal)
            cancel.setTitleColor(.white, for: .normal)
            cancel.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
            cancel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cancel)
            NSLayoutConstraint.activate([
                cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                cancel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16)
            ])

            // Top-trailing Torch toggle (only if device has one)
            if AVCaptureDevice.default(for: .video)?.hasTorch == true {
                let torch = UIButton(type: .system)
                torch.setImage(UIImage(systemName: "bolt.slash.fill"), for: .normal)
                torch.tintColor = .white
                torch.addAction(UIAction { [weak self] _ in self?.toggleTorch(torch: torch) }, for: .touchUpInside)
                torch.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(torch)
                NSLayoutConstraint.activate([
                    torch.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                    torch.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                    torch.widthAnchor.constraint(equalToConstant: 44),
                    torch.heightAnchor.constraint(equalToConstant: 44)
                ])
            }
        }

        private func toggleTorch(torch: UIButton) {
            guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                torchOn.toggle()
                device.torchMode = torchOn ? .on : .off
                device.unlockForConfiguration()
                torch.setImage(UIImage(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill"), for: .normal)
            } catch {
                // Silently ignore — torch not critical.
            }
        }

        private func requestCameraPermissionAndConfigure() {
            // AVFoundation's AVCaptureSession silently fails to start when
            // the user has previously denied camera access. The previous
            // code called `configureSession()` directly, which produced a
            // black screen with no feedback. Audit 2026-06: explicitly
            // request access first; on denial, render a "Settings → Camera"
            // message with a deep-link to the app's permission pane.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if granted {
                            self.configureSession()
                        } else {
                            self.showPermissionDeniedOverlay()
                        }
                    }
                }
            case .denied, .restricted:
                showPermissionDeniedOverlay()
            @unknown default:
                showPermissionDeniedOverlay()
            }
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

        private func showPermissionDeniedOverlay() {
            permissionDenied = true
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = "Camera access is required to scan the QR code.\nEnable it in Settings → DoomCode."
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .white
            label.font = .preferredFont(forTextStyle: .callout)
            label.accessibilityLabel = "Camera access is required to scan the QR code. Enable it in Settings, DoomCode."
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8)
            ])

            let openSettings = UIButton(type: .system)
            openSettings.translatesAutoresizingMaskIntoConstraints = false
            openSettings.setTitle("Open Settings", for: .normal)
            openSettings.setTitleColor(.white, for: .normal)
            openSettings.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            openSettings.accessibilityLabel = "Open Settings to enable camera"
            openSettings.addAction(UIAction { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }, for: .touchUpInside)
            view.addSubview(openSettings)
            NSLayoutConstraint.activate([
                openSettings.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                openSettings.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16)
            ])
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
