// ConnectionsView.swift — DoomCoder Mac
// Redesigned Connections tab. Lists paired iOS devices, exposes
// "Add iPhone" pairing flow, and routes into detail / remove dialogs.

import SwiftUI
import DoomCoderCore

struct ConnectionsView: View {
    @ObservedObject private var store = PairingStore.shared
    @StateObject private var coordinator = MacPairingCoordinator.shared
    @State private var showingPairSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showingPairSheet) {
            PairSheet()
        }
    }

    private var header: some View {
        HStack {
            Text("Paired iPhones & iPads")
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                // v2.8: open the sheet FIRST so the user sees a skeleton
                // immediately while the modifyRecords round-trip runs
                // in the background. Otherwise the sheet would have a
                // visible lag equal to the share-creation latency.
                showingPairSheet = true
                Task { await coordinator.startPairing() }
            } label: {
                Label("Add iPhone", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if store.connections.isEmpty {
            ContentUnavailableView(
                "No paired devices",
                systemImage: "iphone.gen3",
                description: Text("Add an iPhone or iPad to send notifications and status updates to it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.connections) { connection in
                    DeviceRow(connection: connection)
                }
            }
        }
    }
}
