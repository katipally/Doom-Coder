import SwiftUI

// HelpTip — a reusable ⓘ icon that shows a plain-English explanation popover
// when the user hovers over it (macOS hover-only, no tap required).
//
// Usage:
//   HStack { Text("Some Label"); HelpTip("What this control does.") }
//
// The popover appears automatically after a short hover delay and dismisses
// when the cursor leaves. Maximum width is 260pt so text wraps cleanly.

struct HelpTip: View {
    let message: String

    @State private var isVisible = false
    @State private var hoverTask: Task<Void, Never>? = nil

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.tertiary)
            .contentShape(Circle())
            .accessibilityLabel("Help")
            .accessibilityValue(message)
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            withAnimation(DCAnim.fade) { isVisible = true }
                        }
                    }
                } else {
                    withAnimation(DCAnim.fade) { isVisible = false }
                }
            }
            .popover(isPresented: $isVisible, arrowEdge: .bottom) {
                HelpTipPopover(message: message)
            }
    }
}

// MARK: - Popover content

private struct HelpTipPopover: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 260, alignment: .leading)
            .padding(12)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    HStack(spacing: 6) {
        Text("Screen Off")
        HelpTip("Display sleeps after a short delay; Mac CPU stays awake. Saves power and reduces screen burn.")
    }
    .padding(20)
}
#endif
