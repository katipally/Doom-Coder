// PairScannerView.swift — DoomCoder Companion
// Camera-based QR scanner for doomcoder://pair URLs. Uses AVFoundation's
// AVCaptureSession with a metadata-output QR detector. iOS 26-compliant
// actor isolation, explicit camera permission request, and a centered
// scanning reticle for clarity.

import SwiftUI
@preconcurrency import AVFoundation
import DoomCoderCore

struct PairScannerView: View {
    @State private var coordinator = IOSPairingCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var didProcessScan = false
    @State private var permission: CameraPermission = .undetermined

    var body: some View {
        ZStack {
            cameraLayer
            reticle
            bottomCaption
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .tint(.white)
            }
        }
        .task {
            await requestPermissionIfNeeded()
        }
    }

    @ViewBuilder
    private var cameraLayer: some View {
        switch permission {
        case .authorized:
            QRScannerRepresentable { value in
                guard !didProcessScan else { return }
                didProcessScan = true
                Task { await coordinator.handle(scannedString: value) }
            }
            .ignoresSafeArea()
        case .denied:
            permissionDeniedView
        case .undetermined:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    private var reticle: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.85), lineWidth: 3)
                .frame(width: 260, height: 260)
                .overlay {
                    // Subtle corner accents that follow the iOS 26 / Liquid
                    // Glass aesthetic instead of a heavy full border.
                    ReticleCorners()
                        .stroke(Color.white, lineWidth: 5)
                        .frame(width: 260, height: 260)
                }
            Spacer()
        }
    }

    private var bottomCaption: some View {
        VStack {
            Spacer()
            Text("Point at the QR code on the Mac")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
                .padding(.bottom, 32)
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.7))
            Text("Camera access is off")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("DoomCoder needs the camera to scan the pairing QR. Enable Camera in Settings ▸ DoomCoder.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
    }

    private func requestPermissionIfNeeded() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permission = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .authorized : .denied
        case .denied, .restricted:
            permission = .denied
        @unknown default:
            permission = .denied
        }
    }
}

private enum CameraPermission { case undetermined, authorized, denied }

private struct ReticleCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length: CGFloat = 28
        var p = Path()
        // Top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        // Top-right
        p.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        // Bottom-left
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        // Bottom-right
        p.move(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        return p
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ vc: QRScannerViewController, context: Context) {}
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        // iOS 26: setting delegate types before the delegate itself is wired
        // guarantees metadataObjectTypes is non-empty at the time of
        // didOutput delegate callbacks.
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: .main)
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = self.session
        // Hop off the main thread for the (potentially slow) camera warmup
        // so the view appears immediately. We capture `session` as a local
        // non-isolated reference; AVCaptureSession is documented as
        // thread-safe for startRunning/stopRunning (Apple's "Threading
        // Programming Guide" + AVFoundation docs).
        Task.detached(priority: .userInitiated) {
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        Task.detached(priority: .userInitiated) {
            if session.isRunning { session.stopRunning() }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue
        else { return }
        Task { @MainActor in
            onScan?(value)
        }
    }
}
