import SwiftUI

// MARK: - StatusBadge
//
// Traffic-light pill used across the Agent Tracking window. The dot animates
// with `.symbolEffect(.pulse)` when the state implies activity. Deliberately
// tiny — this is the workhorse UI primitive for every row in the sidebar.

struct StatusBadge: View {
    enum Tone {
        case live       // working right now (pulsing green)
        case ready      // set up, idle
        case warn       // attention / partial
        case error      // failed
        case off        // not set up

        var color: Color {
            switch self {
            case .live:  return .green
            case .ready: return .green
            case .warn:  return .yellow
            case .error: return .red
            case .off:   return .secondary
            }
        }

        var symbol: String {
            switch self {
            case .live:  return "circle.fill"
            case .ready: return "checkmark.circle.fill"
            case .warn:  return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .off:   return "circle"
            }
        }
    }

    let tone: Tone
    let text: String?

    init(_ tone: Tone, _ text: String? = nil) {
        self.tone = tone
        self.text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if tone == .live {
                    Image(systemName: tone.symbol)
                        .symbolEffect(.pulse, options: .repeating)
                } else {
                    Image(systemName: tone.symbol)
                }
            }
            .foregroundStyle(tone.color)
            .imageScale(.small)

            if let text {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - GlassSection (convenience wrapper)
//
// A section container with macOS 26 Liquid Glass background. Falls back
// cleanly to `.regularMaterial` if a host view opts out of glass.

struct GlassSection<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            }
    }
}
