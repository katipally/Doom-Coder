// AddMacView.swift — DoomCoder Companion
// Modal sheet that lets the user pair a new Mac. Shows the QR scanner and
// a manual "type the code" fallback. On success it dismisses itself and
// the parent dashboard re-renders the Devices section.
//
// v2.8: iOS 26 Liquid Glass — hero card uses .regularMaterial with a
// 16pt squircle, spring animation on appearance, .symbolEffect(.bounce)
// on the QR glyph.

import SwiftUI
import DoomCoderCore

struct AddMacView: View {
    @State private var coordinator = IOSPairingCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingScanner = false
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                heroCard
                instructions
                Spacer()
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
            .onChange(of: coordinator.phase) { _, newPhase in
                if case .active = newPhase { dismiss() }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(1))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                    appeared = true
                }
            }
        }
    }

    /// v2.8: hero card with Liquid Glass material — the iOS 26
    /// convention for prominent illustration tiles. The squircle
    /// shape (16pt corner radius for a 80x80 card) is the macOS Tahoe
    /// / iOS 26 design language.
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
            Text("Open DoomCoder, go to **Settings → Connections → Add iPhone**, and scan the QR code shown there.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    private var scanButton: some View {
        Button {
            showingScanner = true
        } label: {
            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
