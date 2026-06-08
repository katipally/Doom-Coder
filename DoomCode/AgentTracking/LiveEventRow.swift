import SwiftUI
import DoomCodeCore

// MARK: - LiveEventRow
//
// One row in the "Live Events" section of the Configure window's
// advanced pane. Tapping a row expands the JSON payload (via the
// shared `PayloadRendererView`). Synthetic events (emitted by the
// Connection Doctor) are tinted purple to distinguish them from real
// agent events.
struct LiveEventRow: View {
    let event: LiveEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DCAnim.snap) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(event.timeLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)

                    Text(event.event)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(event.synthetic ? .purple : .primary)

                    if !event.shortCwd.isEmpty {
                        Text(event.shortCwd)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if event.payloadJSON != nil {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .contentTransition(.symbolEffect(.replace))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded, let json = event.payloadJSON {
                PayloadRendererView(json: json)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().opacity(0.4)
        }
    }
}
