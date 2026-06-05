// ConnectionsView.swift — DoomCoder Mac
// Redesigned Connections tab. Lists paired iOS devices, exposes
// "Add Device" pairing flow, and routes into detail / remove dialogs.
// v2.9: empty state shows App Store download link + Add Device button;
// tapping a row opens DeviceDetailView (was previously unwired).

import SwiftUI
import Combine
import DoomCoderCore

private let appStoreURL = URL(string: "https://apps.apple.com/app/doomcoder-companion/id6772514212")!

struct ConnectionsView: View {
    @ObservedObject private var store = PairingStore.shared
    @ObservedObject private var pusher = CloudKitPusher.shared
    @StateObject private var coordinator = MacPairingCoordinator.shared
    @StateObject private var pendingQueue = PendingPairRequestQueue.shared
    @State private var showingPairSheet = false
    @State private var selectedConnection: Connection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !pendingQueue.requests.isEmpty {
                PendingPairRequestBanner(
                    queue: pendingQueue,
                    onAllow: { req in
                        await ConnectionStateChanges.shared.approvePendingRequest(
                            macId: req.macId,
                            iosDeviceId: req.iosDeviceId,
                            iosUserRecordID: req.iosUserRecordID
                        )
                        pendingQueue.remove(req)
                    },
                    onDeny: { req in
                        await ConnectionStateChanges.shared.denyPendingRequest(
                            macId: req.macId,
                            iosDeviceId: req.iosDeviceId,
                            iosUserRecordID: req.iosUserRecordID
                        )
                        pendingQueue.remove(req)
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
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
        HStack(spacing: 12) {
            Text("Paired Devices")
                .font(.title2.weight(.semibold))
            Spacer()
            // v5.2: manual refresh button. Apple's CKSyncEngine
            // documentation explicitly recommends manual
            // fetchChanges() triggers for important updates —
            // silent APNs pushes are coalesced/throttled and
            // can't be relied on. The 10s background safety
            // timer (in CloudKitPusher) is the fallback.
            Button {
                pusher.forceFetch()
            } label: {
                if pusher.isFetching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(pusher.isFetching)
            .help("Refresh paired devices (forces a fresh iCloud fetch)")

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
                ForEach(store.connections, id: \.id) { connection in
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
