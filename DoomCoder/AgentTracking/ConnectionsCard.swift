import SwiftUI

// MARK: - ConnectionsCard
//
// A single grouped section used in the Connections tab. Title + symbol
// header, then a thin-material body. Matches the macOS 26 Settings
// aesthetic (similar to `InnerCard` in `PanelRootView` but with a
// labeled header).
//
// The optional `trailingAction` slot renders a small text + icon button
// in the header row, used to make the "Add Device" CTA discoverable
// even when the user has devices connected and the inline empty-state
// CTA is gone.
struct ConnectionsCard<Content: View>: View {
    let title: String
    let symbol: String
    var trailingAction: (() -> AnyView)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let action = trailingAction {
                    action()
                }
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
            )
        }
    }
}
