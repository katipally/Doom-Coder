import SwiftUI

/// Consistent agent icon rendering for the macOS app.
/// Uses a proportional continuous corner radius (size × 0.22) matching the iOS companion.
struct AgentIconView: View {
    let agent: TrackedAgent
    let size: CGFloat

    var body: some View {
        Image(nsImage: AgentIconProvider.icon(for: agent, size: size))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
