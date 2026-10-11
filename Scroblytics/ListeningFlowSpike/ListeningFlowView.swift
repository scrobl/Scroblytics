import SwiftUI

private struct HoverInfo: Identifiable {
    let id = UUID()
    let point: CGPoint
    let lines: [String]
}

/// Spike: renders the listening-flow graph with SwiftUI `Canvas`/`Path`,
/// to test whether Canvas handles this hand-rolled visualization well enough to
/// generalize to the other custom charts (Rabbit Hole, etc.) — see the native
/// rewrite kickoff brief.
struct ListeningFlowView: View {
    @State private var artistCount: Double = 15
    @State private var nodeCap: Double = 15
    @State private var showCompare = false
    @State private var focusId: String? = nil
    @State private var hover: HoverInfo? = nil

    private var data: FlowData {
        ListeningFlowSampleData.generate(artistCount: Int(artistCount), includeCompare: showCompare)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            GeometryReader { geo in
                let layout = computeFlowLayout(
                    data: data,
                    width: geo.size.width,
                    nodeCap: Int(nodeCap),
                    focusId: focusId
                )
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor))
                    if let layout {
                        ScrollView(.horizontal, showsIndicators: true) {
                            ZStack(alignment: .topLeading) {
                                canvas(for: layout)
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let location):
                                            hover = hitTest(layout: layout, at: location)
                                        case .ended:
                                            hover = nil
                                        }
                                    }
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 0)
                                            .onEnded { value in
                                                if let hit = hitTestNode(layout: layout, at: value.location) {
                                                    focusId = (focusId == hit) ? nil : hit
                                                }
                                            }
                                    )
                                if let hover {
                                    tooltip(hover)
                                }
                            }
                            .frame(width: layout.svgWidth, height: ListeningFlowLayoutConstants.height)
                        }
                    } else {
                        Text("Not enough session data yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(height: ListeningFlowLayoutConstants.height)
            legend
        }
        .padding(20)
        .frame(minWidth: 320, minHeight: 560)
    }

    // MARK: - Header / controls

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trends").font(.title2.bold())
            Text("Which artists you play right after another, within a session")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Artists in graph: \(Int(artistCount))").font(.caption)
                    Slider(value: $artistCount, in: 5...35, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Show top: \(Int(nodeCap))").font(.caption)
                    Slider(value: $nodeCap, in: 5...35, step: 1)
                }
                Toggle("Compare", isOn: $showCompare)
                if focusId != nil {
                    Button("Show all") { focusId = nil }
                }
            }
            .frame(maxWidth: 500)
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            Label("Session starter", systemImage: "play.fill").font(.caption).foregroundStyle(.green)
            Label("Session ender", systemImage: "stop.fill").font(.caption).foregroundStyle(.red)
            Text("Colors group loosely-connected clusters").font(.caption).foregroundStyle(.tertiary)
            if showCompare {
                Text("· Dashed = new · Dotted = dropped").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Canvas drawing

    private func canvas(for layout: FlowLayout) -> some View {
        Canvas { context, size in
            let baseY = ListeningFlowLayoutConstants.baseY
            let arcAvail = baseY - ListeningFlowLayoutConstants.topPad
            func peak(for dist: CGFloat) -> CGFloat {
                guard layout.maxDist > 0 else { return arcAvail }
                return ListeningFlowLayoutConstants.arcMinPeak
                    + (arcAvail - ListeningFlowLayoutConstants.arcMinPeak) * (dist / layout.maxDist)
            }

            // Edges (drawn first so nodes sit on top).
            for edge in layout.edges {
                guard let s = layout.posById[edge.source], let t = layout.posById[edge.target] else { continue }
                let ratio = Double(edge.count) / Double(layout.maxCount)
                let dist = abs(t.x - s.x)
                let cy = baseY - peak(for: dist)
                let midX = (s.x + t.x) / 2
                let dir: CGFloat = t.x >= s.x ? 1 : -1
                let ex = t.x - dir * (t.r + 7)
                let ey = baseY

                let a = atan2(ey - cy, ex - midX)
                let ah: CGFloat = 6, aw: CGFloat = 4
                let bx = ex - ah * cos(a)
                let by = ey - ah * sin(a)
                let perpX = -sin(a), perpY = cos(a)
                var arrow = Path()
                arrow.move(to: CGPoint(x: ex, y: ey))
                arrow.addLine(to: CGPoint(x: bx + aw * perpX, y: by + aw * perpY))
                arrow.addLine(to: CGPoint(x: bx - aw * perpX, y: by - aw * perpY))
                arrow.closeSubpath()

                let dropped = edge.status == .dropped
                let color: Color = dropped ? .gray : s.color
                let opacity = dropped ? 0.18 + ratio * 0.2 : 0.22 + ratio * 0.5
                let strokeWidth = 1 + ratio * 5

                var arc = Path()
                arc.move(to: CGPoint(x: s.x, y: baseY))
                arc.addQuadCurve(to: CGPoint(x: ex, y: ey), control: CGPoint(x: midX, y: cy))

                var style = StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                if edge.status == .new { style.dash = [5, 3] }
                if edge.status == .dropped { style.dash = [1, 4] }

                context.stroke(arc, with: .color(color.opacity(opacity)), style: style)
                context.fill(arrow, with: .color(color.opacity(min(1, opacity + 0.2))))
            }

            // Nodes.
            for laid in layout.laidOut {
                let isFocused = laid.id == layout.focusedId
                if isFocused {
                    let ring = Path(ellipseIn: CGRect(x: laid.x - laid.r - 4, y: baseY - laid.r - 4, width: (laid.r + 4) * 2, height: (laid.r + 4) * 2))
                    context.stroke(ring, with: .color(laid.color.opacity(0.5)), lineWidth: 1.5)
                }
                let circle = Path(ellipseIn: CGRect(x: laid.x - laid.r, y: baseY - laid.r, width: laid.r * 2, height: laid.r * 2))
                let fillOpacity = laid.node.plays > 0 ? (isFocused ? 0.8 : 0.55) : 0
                context.fill(circle, with: .color(laid.color.opacity(fillOpacity)))
                context.stroke(circle, with: .color(laid.color.opacity(0.85)), lineWidth: laid.node.role != nil || isFocused ? 2.5 : 1.25)

                if let role = laid.node.role {
                    let gy = baseY + laid.r + 8
                    switch role {
                    case .starter:
                        var tri = Path()
                        tri.move(to: CGPoint(x: laid.x - 3, y: gy - 3))
                        tri.addLine(to: CGPoint(x: laid.x + 3, y: gy))
                        tri.addLine(to: CGPoint(x: laid.x - 3, y: gy + 3))
                        tri.closeSubpath()
                        context.fill(tri, with: .color(.green))
                    case .ender:
                        let rect = Path(roundedRect: CGRect(x: laid.x - 3, y: gy - 3, width: 6, height: 6), cornerRadius: 1)
                        context.fill(rect, with: .color(.red))
                    }
                }

                let label = laid.id.count > 14 ? String(laid.id.prefix(13)) + "…" : laid.id
                context.drawLayer { layerContext in
                    layerContext.translateBy(x: laid.x, y: baseY + laid.r + 20)
                    layerContext.rotate(by: .degrees(-40))
                    layerContext.draw(
                        Text(label).font(.system(size: 9)).foregroundColor(.secondary),
                        at: .zero,
                        anchor: .trailing
                    )
                }
            }
        }
    }

    // MARK: - Hit testing (Canvas has no built-in per-shape gestures)

    private func hitTestNode(layout: FlowLayout, at point: CGPoint) -> String? {
        for laid in layout.laidOut {
            let d = hypot(point.x - laid.x, point.y - ListeningFlowLayoutConstants.baseY)
            if d <= laid.r + 4 { return laid.id }
        }
        return nil
    }

    private func hitTest(layout: FlowLayout, at point: CGPoint) -> HoverInfo? {
        if let nodeId = hitTestNode(layout: layout, at: point), let laid = layout.posById[nodeId] {
            var lines = [laid.id, "\(laid.node.plays) plays", "\(laid.node.outDegree) out · \(laid.node.inDegree) in"]
            if let role = laid.node.role {
                lines.append(role == .starter ? "Session starter" : "Session ender")
            }
            return HoverInfo(point: point, lines: lines)
        }

        let baseY = ListeningFlowLayoutConstants.baseY
        let arcAvail = baseY - ListeningFlowLayoutConstants.topPad
        for edge in layout.edges {
            guard let s = layout.posById[edge.source], let t = layout.posById[edge.target] else { continue }
            let dist = abs(t.x - s.x)
            let peak: CGFloat = layout.maxDist > 0
                ? ListeningFlowLayoutConstants.arcMinPeak + (arcAvail - ListeningFlowLayoutConstants.arcMinPeak) * (dist / layout.maxDist)
                : arcAvail
            let cy = baseY - peak
            let midX = (s.x + t.x) / 2
            let dir: CGFloat = t.x >= s.x ? 1 : -1
            let ex = t.x - dir * (t.r + 7)

            // Sample the quadratic bezier to approximate distance-to-curve.
            var minDist: CGFloat = .greatestFiniteMagnitude
            let samples = 24
            for i in 0...samples {
                let tt = CGFloat(i) / CGFloat(samples)
                let x = (1 - tt) * (1 - tt) * s.x + 2 * (1 - tt) * tt * midX + tt * tt * ex
                let y = (1 - tt) * (1 - tt) * baseY + 2 * (1 - tt) * tt * cy + tt * tt * baseY
                minDist = min(minDist, hypot(point.x - x, point.y - y))
            }
            let ratio = Double(edge.count) / Double(layout.maxCount)
            let strokeWidth = 1 + ratio * 5
            let tolerance = max(10, strokeWidth + 8)
            if minDist <= tolerance {
                return HoverInfo(point: point, lines: ["\(edge.source) → \(edge.target)", "\(edge.count) transitions"])
            }
        }
        return nil
    }

    private func tooltip(_ hover: HoverInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(hover.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .offset(x: hover.point.x + 12, y: hover.point.y + 12)
        .allowsHitTesting(false)
    }
}

#Preview {
    ListeningFlowView()
}
