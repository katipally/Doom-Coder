import SwiftUI
import AppKit

// 2D session-map canvas.
//
// Layout (left → right, top → bottom):
//   ┌─ Project: ~/myapp ─────────────────────────────────────────────┐
//   │ [Label 150pt] ○───[●]────[●]──────[■]  ← Claude session lane  │
//   │                   │      │                                      │
//   │               [·][·][·] [·][·]         ← event chains         │
//   │ [Label 150pt] ○───[●]──────────────●   ← Cursor session lane  │
//   └─────────────────────────────────────────────────────────────────┘
//
// X-axis = time (shared across all lanes in a cluster).
// Y-axis = stacked lanes.
//
// Hit targets are computed as pure layout math in the view body (no Canvas
// side effects), then used for a transparent overlay so taps route correctly.

struct SessionMapCanvas: View {
    let clusters: [MapProjectCluster]
    let viewModel: SessionMapViewModel

    // Layout constants
    static let labelW:        CGFloat = 150
    static let laneH:         CGFloat = 96
    static let headerH:       CGFloat = 26
    static let nodeR:         CGFloat = 6
    static let eventR:        CGFloat = 3.5
    static let eventStep:     CGFloat = 13
    static let maxEventsShown: Int    = 5
    static let minPtsPerSec:  CGFloat = 0.4  // minimum 0.4 pts per second

    var body: some View {
        GeometryReader { geo in
            let timeRange = computeTimeRange()
            let rangeSec = max(1, timeRange.upperBound.timeIntervalSince(timeRange.lowerBound))
            let availW = max(geo.size.width - Self.labelW - 32, 200)
            // Enforce minPtsPerSec: scale can't go below 0.4 pts/s
            let scale = max(CGFloat(availW) / CGFloat(rangeSec), Self.minPtsPerSec)
            let totalH = computeTotalHeight()
            let canvasW = max(geo.size.width, Self.labelW + CGFloat(rangeSec) * scale + 32)
            let canvasH = max(totalH, geo.size.height)
            let origin = timeRange.lowerBound

            // Compute hit targets purely in view body — no @State mutation inside Canvas.
            let hitTargets = computeHitTargets(origin: origin, scale: scale,
                                               canvasWidth: canvasW)

            // Capture selectedID by value before the Canvas closure so the
            // @Sendable closure doesn't race on the @MainActor viewModel.
            let selectedID = viewModel.selectedEventID

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        renderAll(ctx: &ctx, size: size, origin: origin, scale: scale,
                                  selectedID: selectedID)
                    }

                    // Transparent hit-target overlay
                    ForEach(hitTargets, id: \.id) { target in
                        Color.clear
                            .frame(width: target.rect.width, height: target.rect.height)
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.selectEvent(id: target.id) }
                            .position(x: target.rect.midX, y: target.rect.midY)
                    }
                }
                .frame(width: canvasW, height: canvasH)
            }
        }
    }

    // MARK: - Hit target computation (pure — no side effects)

    private struct HitTarget: Identifiable {
        let id: UUID
        let rect: CGRect
    }

    private func computeHitTargets(origin: Date, scale: CGFloat,
                                   canvasWidth: CGFloat) -> [HitTarget] {
        var result: [HitTarget] = []
        var y: CGFloat = 0

        for cluster in clusters {
            y += Self.headerH
            for lane in cluster.sessions {
                let lineY = y + 36
                for cycle in lane.promptCycles {
                    guard let first = cycle.events.first else { continue }
                    let promptX = xAt(first.timestamp, origin: origin, scale: scale)
                    guard promptX > Self.labelW + 2, promptX < canvasWidth - 4 else { continue }

                    let promptRect = CGRect(x: promptX - Self.nodeR, y: lineY - Self.nodeR,
                                           width: Self.nodeR * 2, height: Self.nodeR * 2)

                    let eventsToShow = cycle.events.prefix(Self.maxEventsShown)
                    for (idx, ev) in eventsToShow.enumerated() {
                        let ex = xAt(ev.timestamp, origin: origin, scale: scale)
                            .clamped(to: Self.labelW + 2 ... canvasWidth - 4)
                        let ey = lineY + 18 + CGFloat(idx) * Self.eventStep
                        let eventRect = CGRect(x: ex - Self.eventR, y: ey - Self.eventR,
                                              width: Self.eventR * 2, height: Self.eventR * 2)
                        result.append(HitTarget(id: ev.id, rect: eventRect.insetBy(dx: -7, dy: -7)))
                    }

                    // Prompt node itself → selects first event in cycle
                    result.append(HitTarget(id: first.id, rect: promptRect.insetBy(dx: -6, dy: -6)))
                }
                y += Self.laneH
            }
        }
        return result
    }

    // MARK: - Layout helpers

    private func computeTimeRange() -> ClosedRange<Date> {
        var minT = Date()
        var maxT = Date(timeIntervalSince1970: 0)
        for c in clusters {
            for lane in c.sessions {
                if lane.startTime < minT { minT = lane.startTime }
                let end = lane.endTime ?? lane.promptCycles.last?.endTime ?? lane.startTime
                if end > maxT { maxT = end }
            }
        }
        if maxT <= minT { maxT = minT.addingTimeInterval(60) }
        let span = maxT.timeIntervalSince(minT)
        let pad = span * 0.05
        return (minT - pad)...(maxT + pad)
    }

    private func computeTotalHeight() -> CGFloat {
        clusters.reduce(0) { acc, c in acc + Self.headerH + CGFloat(c.sessions.count) * Self.laneH }
    }

    private func xAt(_ date: Date, origin: Date, scale: CGFloat) -> CGFloat {
        Self.labelW + CGFloat(date.timeIntervalSince(origin)) * scale
    }

    // MARK: - Render (drawing only — no return value)

    private func renderAll(ctx: inout GraphicsContext, size: CGSize,
                           origin: Date, scale: CGFloat, selectedID: UUID?) {
        var y: CGFloat = 0

        for cluster in clusters {
            // Cluster header background
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: Self.headerH)),
                     with: .color(.white.opacity(0.05)))

            var attrStr = AttributedString(cluster.cwd)
            attrStr.font = .system(size: 10.5, weight: .semibold)
            attrStr.foregroundColor = .white.opacity(0.55)
            ctx.draw(Text(attrStr), at: CGPoint(x: 12, y: y + Self.headerH / 2), anchor: .leading)

            var hdrLine = Path()
            hdrLine.move(to: CGPoint(x: 0, y: y + Self.headerH))
            hdrLine.addLine(to: CGPoint(x: size.width, y: y + Self.headerH))
            ctx.stroke(hdrLine, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
            y += Self.headerH

            for lane in cluster.sessions {
                renderLane(ctx: &ctx, lane: lane, laneY: y, size: size,
                           origin: origin, scale: scale, selectedID: selectedID)
                y += Self.laneH
            }
        }
    }

    private func renderLane(ctx: inout GraphicsContext, lane: MapSessionLane, laneY: CGFloat,
                             size: CGSize, origin: Date, scale: CGFloat, selectedID: UUID?) {
        // Active lane highlight
        if lane.isActive {
            ctx.fill(Path(CGRect(x: 0, y: laneY, width: size.width, height: Self.laneH)),
                     with: .color(.accentColor.opacity(0.07)))
        }

        // Vertical separator
        var sep = Path()
        sep.move(to: CGPoint(x: 0, y: laneY + Self.laneH))
        sep.addLine(to: CGPoint(x: size.width, y: laneY + Self.laneH))
        ctx.stroke(sep, with: .color(.white.opacity(0.07)), lineWidth: 0.5)

        // Left label
        var agentAttr = AttributedString(lane.agent.displayName)
        agentAttr.font = .system(size: 10, weight: .medium)
        agentAttr.foregroundColor = .white.opacity(0.75)
        ctx.draw(Text(agentAttr), at: CGPoint(x: 10, y: laneY + 14), anchor: .leading)

        let shortID = String(lane.sessionKey.suffix(8))
        var idAttr = AttributedString(shortID)
        idAttr.font = .system(size: 8.5)
        idAttr.foregroundColor = .white.opacity(0.28)
        ctx.draw(Text(idAttr), at: CGPoint(x: 10, y: laneY + 28), anchor: .leading)

        let stateStr = lane.displayState.humanReadable
        var stateAttr = AttributedString(stateStr)
        stateAttr.font = .system(size: 8.5)
        stateAttr.foregroundColor = stateColor(lane.displayState).opacity(0.85)
        ctx.draw(Text(stateAttr), at: CGPoint(x: 10, y: laneY + 40), anchor: .leading)

        // Timeline
        let lineY = laneY + 36
        let lineColor = stateColor(lane.displayState)
        let startX = xAt(lane.startTime, origin: origin, scale: scale)
        let endX: CGFloat = {
            if let et = lane.endTime { return xAt(et, origin: origin, scale: scale) }
            let lastTs = lane.promptCycles.last?.endTime ?? lane.startTime
            return xAt(max(lastTs, Date()), origin: origin, scale: scale)
        }()
        let clampedEndX = min(endX, size.width - 8)

        var line = Path()
        line.move(to: CGPoint(x: startX, y: lineY))
        line.addLine(to: CGPoint(x: clampedEndX, y: lineY))
        ctx.stroke(line, with: .color(lineColor.opacity(0.35)), lineWidth: 1.5)

        let startCircle = CGRect(x: startX - 5, y: lineY - 5, width: 10, height: 10)
        ctx.stroke(Path(ellipseIn: startCircle), with: .color(lineColor.opacity(0.7)), lineWidth: 1.5)

        if lane.endTime != nil {
            let endMarkerRect = CGRect(x: clampedEndX - 5, y: lineY - 5, width: 10, height: 10)
            let endColor: Color = lane.displayState == .failed ? .red : .green
            ctx.fill(Path(endMarkerRect), with: .color(endColor.opacity(0.8)))
        } else if lane.isLive {
            let liveRect = CGRect(x: clampedEndX - 4, y: lineY - 4, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: liveRect), with: .color(lineColor.opacity(0.9)))
        }

        // Prompt cycles and event chains
        for cycle in lane.promptCycles {
            guard let first = cycle.events.first else { continue }
            let promptX = xAt(first.timestamp, origin: origin, scale: scale)
            guard promptX > Self.labelW + 2, promptX < size.width - 4 else { continue }

            let promptColor = cycleNodeColor(cycle.status)
            let promptRect = CGRect(x: promptX - Self.nodeR, y: lineY - Self.nodeR,
                                    width: Self.nodeR * 2, height: Self.nodeR * 2)
            ctx.fill(Path(ellipseIn: promptRect), with: .color(promptColor))
            ctx.stroke(Path(ellipseIn: promptRect), with: .color(.white.opacity(0.4)), lineWidth: 0.5)

            let eventsToShow = cycle.events.prefix(Self.maxEventsShown)
            var prevPoint = CGPoint(x: promptX, y: lineY + Self.nodeR)

            for (idx, ev) in eventsToShow.enumerated() {
                let ex = xAt(ev.timestamp, origin: origin, scale: scale)
                    .clamped(to: Self.labelW + 2 ... size.width - 4)
                let ey = lineY + 18 + CGFloat(idx) * Self.eventStep

                var connector = Path()
                connector.move(to: prevPoint)
                connector.addLine(to: CGPoint(x: ex, y: ey))
                ctx.stroke(connector, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                prevPoint = CGPoint(x: ex, y: ey)

                let ec = phaseColor(ev.phase)
                let eventRect = CGRect(x: ex - Self.eventR, y: ey - Self.eventR,
                                      width: Self.eventR * 2, height: Self.eventR * 2)

                if selectedID == ev.id {
                    ctx.fill(Path(ellipseIn: eventRect.insetBy(dx: -2, dy: -2)), with: .color(.white.opacity(0.3)))
                }
                ctx.fill(Path(ellipseIn: eventRect), with: .color(ec))
            }

            let overflow = cycle.events.count - Self.maxEventsShown
            if overflow > 0 {
                let moreY = lineY + 18 + CGFloat(Self.maxEventsShown) * Self.eventStep
                var more = AttributedString("+\(overflow)")
                more.font = .system(size: 7.5)
                more.foregroundColor = .white.opacity(0.3)
                ctx.draw(Text(more), at: CGPoint(x: promptX + 5, y: moreY), anchor: .leading)
            }
        }
    }

    // MARK: - Color helpers

    private func stateColor(_ state: AgentSessionState) -> Color {
        switch state {
        case .running:          return .blue
        case .waitingInput:     return .purple
        case .waitingApproval:  return .orange
        case .completed:        return .green
        case .failed:           return .red
        }
    }

    private func cycleNodeColor(_ status: MapNodeStatus) -> Color {
        switch status {
        case .running:  return .blue
        case .done:     return .green
        case .error:    return .red
        case .waiting:  return .orange
        case .unknown:  return .gray
        }
    }

    private func phaseColor(_ phase: NormalizedEventPhase) -> Color {
        switch phase {
        case .sessionStart:      return .cyan.opacity(0.8)
        case .sessionEnd:        return .green
        case .userPrompt:        return .yellow.opacity(0.85)
        case .toolStart:         return .blue.opacity(0.75)
        case .toolEnd:           return .green.opacity(0.75)
        case .toolError, .error: return .red.opacity(0.85)
        case .permissionNeeded:  return .orange.opacity(0.9)
        case .agentResponse:     return .purple.opacity(0.8)
        case .subagentStart,
             .subagentEnd:       return .teal.opacity(0.75)
        case .fileChanged:       return .white.opacity(0.4)
        case .other:             return .white.opacity(0.25)
        }
    }
}

// MARK: - Comparable clamp helper

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
