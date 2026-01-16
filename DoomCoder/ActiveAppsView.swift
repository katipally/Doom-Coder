import SwiftUI

// Separate window showing all detected AI apps with their running status and CPU usage.
// Opened via "Active Apps…" in the menu bar.
struct ActiveAppsView: View {
    @Bindable var appDetector: AppDetector
    @Bindable var sleepManager: SleepManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420, height: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Active Apps")
                .font(.headline)
            Spacer()
            Button("Scan") { appDetector.refresh() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Re-scan for installed AI apps and CLI tools")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appDetector.detectedApps.isEmpty {
            emptyState
        } else {
            appTable
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No AI apps detected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Click Scan to search for installed apps and CLI tools")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Scan Apps") { appDetector.refresh() }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var appTable: some View {
        Table(appDetector.detectedApps) {
            TableColumn("App") { app in
                HStack(spacing: 8) {
                    Circle()
                        .fill(app.isRunning ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                    Text(app.displayName)
                        .foregroundStyle(app.isRunning ? .primary : .secondary)
                }
            }
            TableColumn("Status") { app in
                Text(statusLabel(app))
                    .foregroundStyle(app.isRunning ? .primary : .tertiary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)

            TableColumn("CPU") { app in
                Text(cpuLabel(app))
                    .foregroundStyle(cpuColor(app))
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: thermalIcon)
                .foregroundStyle(thermalColor)
                .imageScale(.small)
            Text("Thermal: \(sleepManager.thermalStateText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(appDetector.detectedApps.count) app\(appDetector.detectedApps.count == 1 ? "" : "s") detected")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func statusLabel(_ app: TrackedApp) -> String {
        guard app.isRunning else { return "not running" }
        if let cpu = app.cpuPercent { return cpu < 1.0 ? "idle" : "active" }
        return "running"
    }

    private func cpuLabel(_ app: TrackedApp) -> String {
        guard app.isRunning, let cpu = app.cpuPercent else { return "—" }
        return cpu < 0.1 ? "< 0.1%" : String(format: "%.1f%%", cpu)
    }

    private func cpuColor(_ app: TrackedApp) -> Color {
        guard app.isRunning, let cpu = app.cpuPercent else { return .secondary }
        if cpu > 50 { return .red }
        if cpu > 10 { return .orange }
        return .secondary
    }

    private var thermalIcon: String {
        switch sleepManager.thermalStateText {
        case "Critical": return "thermometer.sun.fill"
        case "Serious":  return "thermometer.medium"
        case "Fair":     return "thermometer.low"
        default:         return "thermometer.variable"
        }
    }

    private var thermalColor: Color {
        switch sleepManager.thermalStateText {
        case "Critical": return .red
        case "Serious":  return .orange
        case "Fair":     return .yellow
        default:         return .green
        }
    }
}
