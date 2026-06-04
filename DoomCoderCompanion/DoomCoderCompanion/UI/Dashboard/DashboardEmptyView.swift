// DashboardEmptyView.swift — DoomCoder Companion
// Empty state for the Dashboard's Agents section. Mirrors the original
// "No Agents Yet" copy plus a "Add a Mac" link so the user can pair a
// device on a different Apple ID without hunting through Settings.

import SwiftUI

struct DashboardEmptyView: View {
    @State private var showingAddMac = false

    var body: some View {
        ContentUnavailableView {
            Label("No Agents Yet", systemImage: "macbook.and.iphone")
        } description: {
            Text("Agents on your Mac will appear here automatically once DoomCoder is running on the Mac.")
        } actions: {
            Button("Add a Mac") { showingAddMac = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
        .sheet(isPresented: $showingAddMac) {
            AddMacView()
        }
    }
}
