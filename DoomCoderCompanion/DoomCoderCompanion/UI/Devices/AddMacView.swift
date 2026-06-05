// AddMacView.swift — DoomCoder Companion
// Modal sheet that lets the user pair a new Mac. Three pairing paths:
//   1. Scan QR code shown on the Mac (fastest)
//   2. Type the 6-char code shown below the QR (hands-free)
//   3. Paste the pairing link copied from the Mac (remote / async)
//
// v2.8: iOS 26 Liquid Glass — hero card uses .regularMaterial with a
// 16pt squircle, spring animation on appearance, .symbolEffect(.bounce)
// on the QR glyph.
// v2.9: added code-entry sheet and error banner.

import SwiftUI
import DoomCoderCore

struct AddMacView: View {
    @State private var coordinator = IOSPairingCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingScanner = false
    @State private var showingLinkEntry = false
    @State private var showingCodeEntry = false
    @State private var pastedLink = ""
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                heroCard
                instructions
                Spacer()
                if case .failed(let err) = coordinator.phase {
                    errorBanner(err)
                }
                scanButton
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingScanner) {
                PairScannerView()
            }
            .sheet(isPresented: $showingLinkEntry) {
                pasteLinkSheet
            }
            .sheet(isPresented: $showingCodeEntry) {
                CodeEntrySheet(coordinator: coordinator)
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
    }

    private var heroCard: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, options: .repeating, value: appeared)
            }
            .frame(width: 96, height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
            Text("Pair a Mac")
                .font(.title2.weight(.semibold))
        }
        .scaleEffect(appeared ? 1.0 : 0.9)
        .opacity(appeared ? 1.0 : 0.0)
    }

    private var instructions: some View {
        VStack(spacing: 8) {
            Text("On the Mac")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Open DoomCoder, go to **Settings → Connections → Add Device**, then scan the QR code or type the 6-character code shown there.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
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

    private var scanButton: some View {
        VStack(spacing: 12) {
            Button {
                showingScanner = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                coordinator.reset()
                showingCodeEntry = true
            } label: {
                Label("Enter Pairing Code", systemImage: "keyboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                pastedLink = UIPasteboard.general.string ?? ""
                showingLinkEntry = true
            } label: {
                Label("Paste Pairing Link", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var pasteLinkSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("doomcoder://pair?ckShareURL=…", text: $pastedLink)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Paste the pairing link from the Mac")
                } footer: {
                    Text("On the Mac, tap **Copy Pairing Link** in the Add Device sheet and paste it here.")
                }

                Section {
                    Button("Connect") {
                        let link = pastedLink.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: link) else { return }
                        showingLinkEntry = false
                        Task { await coordinator.handle(pairURL: url) }
                    }
                    .disabled(pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Pairing Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingLinkEntry = false }
                }
            }
        }
    }
}

// MARK: - Code Entry Sheet

private struct CodeEntrySheet: View {
    let coordinator: IOSPairingCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @FocusState private var focused: Bool

    private var isBusy: Bool {
        switch coordinator.phase {
        case .awaitingSystemAcceptance, .accepting: return true
        default: return false
        }
    }

    private var codeError: ConnectionError? {
        if case .failed(let err) = coordinator.phase { return err }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Image(systemName: "keyboard.badge.eye")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .padding(.top, 16)

                Text("Type the 6-character code shown below the QR on the Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.horizontal, 24)

                TextField("A1B2C3", text: $code)
                    .font(.system(size: 42, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .focused($focused)
                    .onChange(of: code) { _, v in
                        code = String(v.uppercased().prefix(6))
                    }
                    .padding(.horizontal, 16)

                if let err = codeError {
                    HStack(spacing: 8) {
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
                    .padding(.horizontal, 16)
                }

                Button {
                    Task { await coordinator.resolveCode(code) }
                } label: {
                    Group {
                        if isBusy {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(.white)
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
                .padding(.horizontal, 16)

                Spacer()
            }
            .navigationTitle("Enter Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: coordinator.phase) { _, phase in
                if case .active = phase { dismiss() }
            }
            .onAppear { focused = true }
        }
    }
}
