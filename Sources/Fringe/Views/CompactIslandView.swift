import SwiftUI

/// Collapsed wings filled by whatever widget won `island()`. Same silhouette
/// as the old native media/battery islands — only the occupants are a script
/// tree now.
struct CompactIslandView: View {
    let claim: IslandClaim
    let layout: NotchSettings.IslandLayout
    let context: WidgetRenderContext

    var body: some View {
        HStack(spacing: 0) {
            wing(claim.left)
            Color.clear.frame(width: layout.notchWidth)
            wing(claim.right)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .allowsHitTesting(false)
    }

    /// Height is the content square so art, glyphs, and the equaliser share a
    /// box. Width is the whole wing: `"100%"` cannot fit in that square, which
    /// is why the wing is wider than it is tall.
    private func wing(_ node: WidgetNode) -> some View {
        WidgetNodeView(node: node, context: context)
            .frame(maxWidth: layout.wingWidth, maxHeight: layout.contentSide)
            .frame(width: layout.wingWidth, height: layout.size.height)
    }
}

/// Three bars rising from a baseline while audio plays, settling flat when
/// paused — the system's now-playing equaliser.
struct PlayingIndicator: View {
    var isPlaying: Bool
    /// Side of the square this is centred in. Every proportion derives from it.
    var size: CGFloat
    /// Blurred artwork used to colour the bars. Falls back to white.
    var tint: NSImage?

    /// Thin relative to their height — that ratio is what makes them read as an
    /// equaliser. Sizing bars to fill the box's width instead gives squat
    /// blocks roughly as wide as they are tall.
    private var barWidth: CGFloat { max(2, (size * 0.16).rounded()) }
    private var barSpacing: CGFloat { barWidth }
    private var maxBar: CGFloat { (size * 0.8).rounded() }

    /// Bars never drop below this while playing. Letting them fall to the bar
    /// width turns the equaliser into three blinking dots.
    private var floorBar: CGFloat { (maxBar * 0.35).rounded() }

    /// Paused: collapsed to stubs on the baseline.
    private var restBar: CGFloat { barWidth }

    /// Deliberately non-harmonic rates, so the bars never settle into a visible
    /// repeating pattern the way a single shared sine does.
    private let rates: [Double] = [3.3, 4.7, 2.5]
    private let offsets: [Double] = [0, 1.7, 3.1]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            // The bars are a mask cut out of the colour source, rather than
            // shapes with a fill — that way the artwork's palette runs across
            // the whole group instead of each bar being a flat colour.
            fill
                .frame(width: size, height: size)
                .mask {
                    // .bottom matters: these are bars standing on a baseline,
                    // not shapes growing out of their own centre.
                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule(style: .continuous)
                                .frame(width: barWidth, height: height(index: index, time: time))
                        }
                    }
                    // Fixed to the tallest bar so the baseline cannot shift as
                    // the bars animate, then centred in the box.
                    .frame(height: maxBar, alignment: .bottom)
                    .frame(width: size, height: size)
                }
                .animation(.smooth(duration: 0.25), value: isPlaying)
        }
    }

    @ViewBuilder
    private var fill: some View {
        if let tint {
            Image(nsImage: tint)
                .resizable()
                .scaledToFill()
                .saturation(1.8)
                // Dark artwork would otherwise leave the bars invisible
                // against the black island.
                .overlay {
                    // A shape, not a Color: `Color` is both a View and a
                    // ShapeStyle, which makes `blendMode` ambiguous on it.
                    Rectangle()
                        .fill(.white.opacity(0.22))
                        .blendMode(.plusLighter)
                }
        } else {
            Color.white
        }
    }

    private func height(index: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else { return restBar }

        // Summing two sines at an irrational-ish ratio gives motion that keeps
        // drifting instead of looping, which is what reads as "organic".
        let rate = rates[index]
        let offset = offsets[index]
        let wave = sin(time * rate + offset) * 0.62
            + sin(time * rate * 1.73 + offset * 2.1) * 0.38
        let normalized = (wave + 1) / 2

        return floorBar + CGFloat(normalized) * (maxBar - floorBar)
    }
}
