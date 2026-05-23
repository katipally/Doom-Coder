// EmptyStateView.swift — DoomCoder Companion
// Empty state when no agents are configured yet

import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 12) {
                Text("No Agents Yet")
                    .font(.title2.bold())
                
                Text("Open DoomCoder on your Mac to start tracking AI agents")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Link(destination: URL(string: "https://github.com/katipally/Doom-Coder/releases")!) {
                Label("Download for Mac", systemImage: "arrow.down.circle")
                    .font(.body.bold())
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
