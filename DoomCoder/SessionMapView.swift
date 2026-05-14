import SwiftUI

// Root view for the Session Map window.
// Left side: scrollable 2D canvas (project clusters → session lanes → event nodes).
// Right side: node detail panel, slides in when a node is tapped.
//
// Live by default; data refreshes whenever AgentTrackingManager.sessions changes
// via withObservationTracking.

struct SessionMapView: View {
    @State private var viewModel = SessionMapViewModel()
    private let tracking = AgentTrackingManager.shared

    private let detailPanelWidth: CGFloat = 280

    var body: some View {
        HStack(spacing: 0) {
            // Canvas
            Group {
                if viewModel.clusters.isEmpty {
                    emptyState
                } else {
                    SessionMapCanvas(clusters: viewModel.clusters, viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Detail panel
            if let event = viewModel.selectedEvent {
                NodeDetailPanel(event: event) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.clearSelection()
                    }
                }
                .frame(width: detailPanelWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .animation(.easeInOut(duration: 0.18), value: viewModel.selectedEvent?.id)
        .onAppear { refresh() }
        .onChange(of: tracking.eventSequence) { _, _ in refresh() }
        .onChange(of: tracking.sessions.count) { _, _ in refresh() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text(toolbarTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No active sessions")
                .font(.title3)
                .foregroundStyle(.primary)
            Text("Start a coding session with any tracked agent\nand events will appear here in real time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var toolbarTitle: String {
        let total = viewModel.clusters.reduce(0) { $0 + $1.sessions.count }
        let live  = viewModel.clusters.flatMap(\.sessions).filter(\.isLive).count
        if total == 0 { return "No sessions" }
        return "\(total) session\(total == 1 ? "" : "s") · \(live) live"
    }

    private func refresh() {
        viewModel.refresh(sessions: tracking.sessions)
    }
}
