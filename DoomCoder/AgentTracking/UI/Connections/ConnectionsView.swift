// ConnectionsView.swift — DoomCoder Mac
// Redesigned Connections tab. Lists paired iOS devices, exposes
// "Add Device" pairing flow, and routes into detail / remove dialogs.
// v2.9: empty state shows App Store download link + Add Device button;
// tapping a row opens DeviceDetailView (was previously unwired).

import SwiftUI
import DoomCoderCore

private let appStoreURL = URL(string: "https://apps.apple.com/app/doomcoder-companion/id6772514212")!

struct ConnectionsView: View {
    @ObservedObject private var store = PairingStore.shared
    @StateObject private var coordinator = MacPairingCoordinator.shared
    @State private var showingPairSheet = false
    @State private var selectedConnection: Connection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showingPairSheet) {
            PairSheet()
        }
        .sheet(item: $selectedConnection) { conn in
            DeviceDetailView(connection: conn)
        }
    }

    private var header: some View {
        HStack {
            Text("Paired Devices")
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                showingPairSheet = true
                Task { await coordinator.startPairing() }
            } label: {
                Label("Add Device", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if store.connections.isEmpty {
            emptyState
        } else {
            List {
                ForEach(store.connections) { connection in
                    DeviceRow(connection: connection) {
                        selectedConnection = connection
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await MacPairingCoordinator.shared.remove(connection: connection) }
                        } label: {
                            Label("Disconnect", systemImage: "minus.circle")
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "iphone.gen3")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No devices paired yet")
                .font(.title3.weight(.semibold))
            Text("Download the DoomCoder companion app on your iPhone or iPad, then tap Add Device to pair.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
            Link(destination: appStoreURL) {
                Label("Download on the App Store", systemImage: "arrow.down.circle")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Button {
                showingPairSheet = true
                Task { await coordinator.startPairing() }
            } label: {
                Label("Add Device", systemImage: "plus")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
