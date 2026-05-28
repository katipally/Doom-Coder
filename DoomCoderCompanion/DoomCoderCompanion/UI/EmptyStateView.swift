// EmptyStateView.swift — DoomCoder Companion
// Shown on the Agents tab when no Mac is connected (or none has published
// agents yet). Never a dead end: offers Connect, the interactive demo, and the
// Mac download.

import SwiftUI

struct EmptyStateView: View {
    @State private var showConnect = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("No Agents Yet")
                    .font(.title2.bold())
                Text("Connect your Mac to see the AI agents running on it. You can also explore a live demo right here.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button {
                    Haptics.tap()
                    showConnect = true
                } label: {
                    Label("Connect your Mac", systemImage: "link")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)

                NavigationLink {
                    DemoView()
                } label: {
                    Label("Try the interactive demo", systemImage: "play.circle")
                }

                Link(destination: URL(string: "https://github.com/katipally/Doom-Coder/releases")!) {
                    Label("Download for Mac", systemImage: "arrow.down.circle")
                }
                .font(.subheadline)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .sheet(isPresented: $showConnect) {
            ConnectFlowView(onFinished: {})
        }
    }
}
