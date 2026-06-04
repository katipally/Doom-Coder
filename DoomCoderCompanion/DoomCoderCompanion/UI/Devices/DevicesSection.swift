// DevicesSection.swift — DoomCoder Companion
// Top section in the Dashboard showing paired Macs. Above the agent list.
// Read-only list with a "Add a Mac" button at the end.

import SwiftUI
import DoomCoderCore

struct DevicesSection: View {
    @State private var store = ConnectionStore.shared
    @Binding var selectedMacId: String?
    @State private var showingAddMac = false

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
                    DeviceRow(
                        connection: connection,
                        isSelected: connection.macDeviceId == selectedMacId
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedMacId = connection.macDeviceId
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
    }
}
