// AddMacView.swift — DoomCoder Companion
// Modal sheet that lets the user pair a new Mac. v5: tabbed
// interface (Scan / Type / Paste / Same iCloud) with iOS 26 sheet
// detents so the QR reticle is always fully visible at .medium
// and the user can swipe up to .large for the keyboard-entry
// fields. v5.1: added the "Same iCloud" tab which renders a
// discoverable list of Macs running DoomCoder on the same iCloud
// account — no QR needed.
//
// Structure:
//   ┌──────────────────────────────┐
//   │  Pair a Mac          [×]    │
//   ├──────────────────────────────┤
//   │  ┌────┬────┬────┬──────────┐  │
//   │  │Scan│Type│Paste│Same iCloud│
//   │  └────┴────┴────┴──────────┘  │
//   │                              │
//   │   [ tab content ]            │
//   │                              │
//   │   error banner (if any)     │
//   └──────────────────────────────┘

import SwiftUI
import DoomCoderCore

struct AddMacView: View {
    @State private var coordinator = IOSPairingCoordinator.shared
    @State private var discoverable = DiscoverableMacSubscription.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: PairingTab = .scan
    @State private var pastedLink: String = ""
    @State private var code: String = ""
    @State private var appeared: Bool = false

    enum PairingTab: String, CaseIterable, Identifiable {
        case scan = "Scan"
        case type = "Type"
        case paste = "Paste"
        case sameICloud = "Same iCloud"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .scan:        return "qrcode.viewfinder"
            case .type:        return "keyboard"
            case .paste:       return "doc.on.clipboard"
            case .sameICloud:  return "icloud"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                Divider()
                    .padding(.top, 4)
                TabContent(
                    tab: selectedTab,
                    coordinator: coordinator,
                    discoverable: discoverable,
                    pastedLink: $pastedLink,
                    code: $code
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: coordinator.phase) { _, newPhase in
                if case .active = newPhase { dismiss() }
            }
            .task {
                coordinator.reset()
                try? await Task.sleep(for: .milliseconds(1))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                    appeared = true
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var tabBar: some View {
        Picker("Pairing method", selection: $selectedTab) {
            ForEach(PairingTab.allCases) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Pairing method")
    }
}

// MARK: - Tab content

private struct TabContent: View {
    let tab: AddMacView.PairingTab
    let coordinator: IOSPairingCoordinator
    @ObservedObject var discoverable: DiscoverableMacSubscription
    @Binding var pastedLink: String
    @Binding var code: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            tabBody
            if case .failed(let err) = coordinator.phase {
                errorBanner(err)
                    .padding(.horizontal, 20)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var tabBody: some View {
        switch tab {
        case .scan:
            ScanTabBody(coordinator: coordinator)
        case .type:
            TypeTabBody(coordinator: coordinator, code: $code)
        case .paste:
            PasteTabBody(coordinator: coordinator, pastedLink: $pastedLink)
        case .sameICloud:
            SameIcloudTab(subscription: discoverable, coordinator: coordinator)
        }
    }

    private func errorBanner(_ err: ConnectionError) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(err.userMessage)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Scan tab

private struct ScanTabBody: View {
    let coordinator: IOSPairingCoordinator
    @State private var showingScanner = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, options: .repeating, value: UUID())
            }
            .frame(width: 96, height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )

            VStack(spacing: 4) {
                Text("Scan the QR on the Mac")
                    .font(.headline)
                Text("On the Mac, open DoomCoder ▸ Settings ▸ Connections ▸ **Add Device**.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            Button {
                showingScanner = true
            } label: {
                Label("Open Camera", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
        }
        .sheet(isPresented: $showingScanner) {
            PairScannerView()
        }
    }
}

// MARK: - Type tab

private struct TypeTabBody: View {
    let coordinator: IOSPairingCoordinator
    @Binding var code: String
    @FocusState private var focused: Bool

    private var isBusy: Bool {
        switch coordinator.phase {
        case .awaitingSystemAcceptance, .accepting: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard.badge.eye")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Text("Type the 6-character code")
                    .font(.headline)
                Text("Shown below the QR on the Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("A1B2C3", text: $code)
                .font(.system(size: 38, weight: .bold, design: .monospaced))
                .tracking(8)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($focused)
                .onChange(of: code) { _, v in
                    code = String(v.uppercased().prefix(6))
                }
                .padding(.horizontal, 32)

            Button {
                Task { await coordinator.resolveCode(code) }
            } label: {
                Group {
                    if isBusy {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Connecting…")
                        }
                    } else {
                        Text("Connect")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(code.count < 6 || isBusy)
            .padding(.horizontal, 32)
        }
        .onAppear { focused = true }
    }
}

// MARK: - Paste tab

private struct PasteTabBody: View {
    let coordinator: IOSPairingCoordinator
    @Binding var pastedLink: String
    @State private var loadOnAppear = true

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Text("Paste a pairing link")
                    .font(.headline)
                Text("Tap **Copy Pairing Link** on the Mac and paste it here. Works from Messages, Mail, or AirDrop.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }

            TextField("doomcoder://pair?ckShareURL=…", text: $pastedLink)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .padding(.horizontal, 32)

            Button {
                if let url = URL(string: pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Task { await coordinator.handle(pairURL: url) }
                }
            } label: {
                Label("Connect", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 32)
        }
        .onAppear {
            guard loadOnAppear else { return }
            loadOnAppear = false
            if pastedLink.isEmpty, let clip = UIPasteboard.general.string {
                pastedLink = clip
            }
        }
    }
}
