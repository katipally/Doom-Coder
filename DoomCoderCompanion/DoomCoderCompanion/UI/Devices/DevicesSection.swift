// DevicesSection.swift — DoomCoder Companion
// Top section in the Dashboard showing paired Macs. Above the agent list.
// Tapping a row selects that Mac (filters the agent list) AND opens
// DeviceDetailView as a sheet where the user can inspect or disconnect.

import SwiftUI
import DoomCoderCore

struct DevicesSection: View {
    @State private var store = ConnectionStore.shared
    @Binding var selectedMacId: String?
    @State private var showingAddMac = false
    @State private var showingDetail: Connection?
    @State private var connectionToRemove: Connection?

    var body: some View {
        Section {
            if store.connections.isEmpty {
                Button {
                    showingAddMac = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                        Text("Add a Mac")
                            .foregroundStyle(.tint)
                        Spacer()
                    }
                }
            } else {
                ForEach(store.connections) { connection in
                    Button {
                        selectedMacId = connection.macDeviceId
                        showingDetail = connection
                    } label: {
                        DeviceRow(
                            connection: connection,
                            isSelected: connection.macDeviceId == selectedMacId
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            connectionToRemove = connection
                        } label: {
                            Label("Disconnect", systemImage: "minus.circle")
                        }
                    }
                    .contextMenu {
                        Button {
                            selectedMacId = connection.macDeviceId
                            showingDetail = connection
                        } label: {
                            Label("View Details", systemImage: "info.circle")
                        }
                        Button(role: .destructive) {
                            connectionToRemove = connection
                        } label: {
                            Label("Disconnect", systemImage: "minus.circle")
                        }
                    }
                }
                Button {
                    showingAddMac = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                        Text("Add another Mac")
                            .foregroundStyle(.tint)
                        Spacer()
                    }
                }
            }
        } header: {
            HStack {
                Text("Devices")
                Spacer()
                if store.connections.count > 1 {
                    Text("\(store.connections.count) paired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingAddMac) {
            AddMacView()
        }
        .sheet(item: $showingDetail) { conn in
            NavigationStack {
                DeviceDetailView(connection: conn)
            }
        }
        .sheet(item: $connectionToRemove) { conn in
            RemoveConnectionDialog(connection: conn) {
                connectionToRemove = nil
            }
        }
    }
}
