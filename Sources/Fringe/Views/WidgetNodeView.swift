import SwiftUI

/// Everything a script's tree needs from the host but cannot express itself:
/// the current artwork, and somewhere to send button actions.
struct WidgetRenderContext {
    var artwork: NSImage?
    var blurredArtwork: NSImage?
    /// Changes when the track does, which is what drives the artwork crossfade.
    var artworkID: Int = 0
    /// False while arranging, so button gestures do not swallow widget drags.
    var isInteractive = true
    var perform: (String) -> Void

    /// For previews and any tree rendered outside the panel. Main-actor bound
    /// because it holds `NSImage`, which is not Sendable.
    @MainActor
    static let inert = WidgetRenderContext(
        artwork: nil,
        blurredArtwork: nil,
        perform: { _ in }
    )

    /// Same artwork fields the island, the board, and the drag preview all
    /// need. Interactive only on the board — button gestures would otherwise
    /// eat the drag that moves a widget.
    @MainActor
    static func nowPlaying(
        _ media: NowPlayingController,
        artwork: Bool = true,
        isInteractive: Bool = false,
        perform: @escaping (String) -> Void = { _ in }
    ) -> WidgetRenderContext {
        WidgetRenderContext(
            artwork: artwork ? media.snapshot?.artwork : nil,
            blurredArtwork: artwork ? media.blurredArtwork : nil,
            artworkID: artwork ? (media.snapshot?.artworkHash ?? 0) : 0,
            isInteractive: isInteractive,
            perform: perform
        )
    }
}

/// Draws the tree a script returned.
struct WidgetNodeView: View {
    let node: WidgetNode
    var context: WidgetRenderContext = .inert

    var body: some View {
        switch node {
        case .text(let text):
            Text(text.value)
                .font(
                    .system(
                        size: text.size,
                        weight: .named(text.weight),
                        design: text.monospaced ? .monospaced : .rounded
                    )
                )
                .foregroundStyle((text.color.map(Color.init(scriptValue:)) ?? .white).opacity(text.opacity))
                .lineLimit(max(1, text.lines))
                .truncationMode(.tail)
                // Shrinking and truncating are alternatives; asking for both
                // means the type scales down before it ever clips.
                .minimumScaleFactor(text.truncate ? 1 : 0.6)
                .multilineTextAlignment(.textAlignment(text.align))
                // Crossfades when the string changes instead of snapping, which
                // matters on a widget that re-renders every second.
                .contentTransition(.opacity)
                .modifier(TextStretch(align: text.align))

        case .symbol(let symbol):
            ScriptSymbol(
                name: symbol.name,
                size: symbol.size,
                opacity: symbol.opacity,
                color: symbol.color,
                secondary: symbol.secondary,
                tertiary: symbol.tertiary,
                rendering: symbol.rendering,
                fit: symbol.fit
            )
            // Morphs play into pause rather than swapping the glyph.
            .contentTransition(.symbolEffect(.replace))

        case .stack(let stack):
            stackView(stack)
                .padding(stack.padding)
                // So a tight cell can actually be proposed inward. Without a
                // zero minimum the stack reports its children's ideal size
                // and the tile never gets a chance to clip them.
                .frame(minWidth: 0, minHeight: 0)

        case .progress(let progress):
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule()
                        .fill(progress.color.map(Color.init(scriptValue:)) ?? .white)
                        .frame(width: proxy.size.width * progress.value)
                }
            }
            .frame(height: progress.height)
            // Scripts poll about once a second, so glide between readings
            // rather than stepping.
            .animation(.linear(duration: 0.9), value: progress.value)

        case .artwork(let artwork):
            artworkView(artwork)

        case .button(let button):
            WidgetButton(
                padding: button.padding,
                isEnabled: context.isInteractive,
                action: { context.perform(button.action) }
            ) {
                WidgetNodeView(node: button.child, context: context)
            }

        case .spacer(let length):
            if let length {
                // `fixedSize` pins the spacer to exactly this along whichever
                // axis its stack runs, so it works in both.
                Spacer(minLength: length).fixedSize()
            } else {
                Spacer(minLength: 0)
            }

        case .list(let list):
            listView(list)

        case .chart(let chart):
            chartView(chart)

        case .equaliser(let equaliser):
            equaliserView(equaliser)
        }
    }

    @ViewBuilder
    private func stackView(_ stack: StackNode) -> some View {
        switch stack.axis {
        case .vertical:
            VStack(alignment: .horizontalAlignment(stack.alignment), spacing: stack.spacing) {
                children(of: stack)
            }
        case .horizontal:
            HStack(alignment: .verticalAlignment(stack.alignment), spacing: stack.spacing) {
                children(of: stack)
            }
        case .layered:
            ZStack {
                children(of: stack)
            }
        }
    }

    private func artworkView(_ artwork: ArtworkNode) -> some View {
        let image = artwork.blurred ? context.blurredArtwork : context.artwork

        // `Color.clear` is the thing being sized; the image rides on top as an
        // overlay. A bare resizable image has no size of its own to constrain,
        // so it reports its full pixel dimensions and bursts out of the tile.
        return Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.08).overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .overlay {
                if artwork.dim > 0 {
                    Rectangle().fill(.black.opacity(artwork.dim))
                }
            }
            .modifier(ArtworkSizing(size: artwork.size, fills: artwork.fill))
            .clipShape(RoundedRectangle(cornerRadius: artwork.cornerRadius, style: .continuous))
            .opacity(artwork.opacity)
            // Keyed on the track so a new cover crossfades in rather than
            // popping — swapping the image alone changes no identity.
            .id(context.artworkID)
            .transition(.opacity)
    }

    @ViewBuilder
    private func equaliserView(_ equaliser: EqualiserNode) -> some View {
        if let size = equaliser.size {
            PlayingIndicator(
                isPlaying: equaliser.playing,
                size: size,
                tint: context.blurredArtwork
            )
        } else {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                PlayingIndicator(
                    isPlaying: equaliser.playing,
                    size: side,
                    tint: context.blurredArtwork
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private func children(of stack: StackNode) -> some View {
        ForEach(Array(stack.children.enumerated()), id: \.offset) { _, child in
            WidgetNodeView(node: child, context: context)
        }
    }

    private func listView(_ list: ListNode) -> some View {
        VStack(spacing: 3) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    if let symbol = item.symbol {
                        ScriptSymbol(
                            name: symbol,
                            size: 11,
                            color: item.color,
                            secondary: item.secondary,
                            tertiary: item.tertiary,
                            rendering: item.rendering
                        )
                        .frame(width: 16)
                    }
                    Text(item.title)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .frame(minWidth: 0)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .frame(minWidth: 0)
                    }
                    Spacer(minLength: 0)
                    if let value = item.value {
                        Text(value)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 0)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func chartView(_ chart: ChartNode) -> some View {
        let tint = chart.color.map(Color.init(scriptValue:)) ?? Color.white
        return Group {
            switch chart.kind {
            case .line:
                ZStack {
                    if chart.fill {
                        Sparkline(values: chart.values, closed: true)
                            .fill(tint.opacity(0.28))
                    }
                    Sparkline(values: chart.values, closed: false)
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            case .bars:
                BarChart(values: chart.values)
                    .fill(tint.opacity(0.85))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: chart.height)
    }
}

/// Tap target for `button` nodes: hover highlight, press-in, and an inset that
/// makes a small glyph actually hittable.
private struct WidgetButton<Content: View>: View {
    let padding: CGFloat
    let isEnabled: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        content
            .padding(padding)
            .background(Circle().fill(.white.opacity(isHovering ? 0.16 : 0)))
            .scaleEffect(isPressed ? 0.86 : 1)
            .contentShape(Circle())
            .onHover { isHovering = isEnabled && $0 }
            .gesture(isEnabled ? press : nil)
            .animation(.spring(response: 0.26, dampingFraction: 0.55), value: isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    /// A zero-distance drag rather than a tap, so the press-in state can track
    /// the mouse being held. Releasing after wandering off counts as a cancel.
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in isPressed = true }
            .onEnded { value in
                isPressed = false
                let slip = max(abs(value.translation.width), abs(value.translation.height))
                if slip < 10 { action() }
            }
    }
}

/// SF Symbol with the rendering mode a script asked for. Default is still a
/// flat white glyph; `palette` is how weather gets a two-tone sun-and-cloud.
private struct ScriptSymbol: View {
    var name: String
    var size: CGFloat
    var opacity: Double = 1
    var color: String?
    var secondary: String?
    var tertiary: String?
    var rendering: String?
    var fit = false

    var body: some View {
        styled(base)
            .opacity(opacity)
            .frame(width: fit ? size : nil, height: fit ? size : nil)
    }

    /// `resizable` has to sit on the Image, not a wrapping View — that is
    /// what actually caps extra-wide glyphs like the battery.
    @ViewBuilder
    private var base: some View {
        if fit {
            Image(systemName: name).resizable().scaledToFit()
        } else {
            Image(systemName: name).font(.system(size: size))
        }
    }

    @ViewBuilder
    private func styled<Content: View>(_ image: Content) -> some View {
        let primary = color.map(Color.init(scriptValue:)) ?? Color.white
        let second = secondary.map(Color.init(scriptValue:)) ?? primary.opacity(0.45)
        let third = tertiary.map(Color.init(scriptValue:)) ?? second.opacity(0.7)
        switch rendering?.lowercased() {
        case "hierarchical":
            image.symbolRenderingMode(.hierarchical).foregroundStyle(primary)
        case "palette":
            image.symbolRenderingMode(.palette).foregroundStyle(primary, second, third)
        case "multicolor":
            image.symbolRenderingMode(.multicolor)
        default:
            image.symbolRenderingMode(.monochrome).foregroundStyle(primary)
        }
    }
}

/// Widens text to the space available so its alignment is visible. Without a
/// frame a `Text` is exactly as wide as its string, and aligning it does
/// nothing.
///
/// `minWidth: 0` is load-bearing either way. Text's own minimum is the
/// untruncated string, and that is what lets a long title shove a tile past
/// its cell. Truncation only happens once the label can actually shrink.
private struct TextStretch: ViewModifier {
    var align: String?

    func body(content: Content) -> some View {
        if let align {
            content.frame(minWidth: 0, maxWidth: .infinity, alignment: .frameAlignment(align))
        } else {
            content.frame(minWidth: 0)
        }
    }
}

private struct ArtworkSizing: ViewModifier {
    var size: CGFloat?
    var fills: Bool

    func body(content: Content) -> some View {
        if let size {
            // A cap, not a floor. `size` exists so a cover cannot eat a wide
            // tile; pinning the frame to exactly that made a 1-wide player
            // refuse to sit in a cell smaller than the art.
            content
                .frame(
                    minWidth: 0,
                    idealWidth: size,
                    maxWidth: size,
                    minHeight: 0,
                    idealHeight: size,
                    maxHeight: size
                )
                .aspectRatio(1, contentMode: .fit)
        } else if fills {
            content.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        } else {
            content.aspectRatio(1, contentMode: .fit)
        }
    }
}

// MARK: - Script value mapping

extension Font.Weight {
    static func named(_ name: String) -> Font.Weight {
        switch name.lowercased() {
        case "ultralight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: .regular
        }
    }
}

extension TextAlignment {
    static func textAlignment(_ name: String?) -> TextAlignment {
        switch name?.lowercased() {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }
}

extension Alignment {
    static func frameAlignment(_ name: String) -> Alignment {
        switch name.lowercased() {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }
}

extension HorizontalAlignment {
    static func horizontalAlignment(_ name: String) -> HorizontalAlignment {
        switch name.lowercased() {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }
}

extension VerticalAlignment {
    static func verticalAlignment(_ name: String) -> VerticalAlignment {
        switch name.lowercased() {
        case "top": .top
        case "bottom": .bottom
        default: .center
        }
    }
}

/// Polyline through `values`, optionally closed down to the baseline so it
/// can be filled. All-equal series collapse to a midline rather than a
/// divide-by-zero.
private struct Sparkline: Shape {
    var values: [Double]
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        let points = ChartScaling.points(values: values, in: rect)
        guard let first = points.first else { return Path() }

        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        if closed, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

private struct BarChart: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        guard !values.isEmpty else { return Path() }
        let range = ChartScaling.range(values)
        let gap: CGFloat = 2
        let width = max(1, (rect.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count))

        var path = Path()
        for (index, value) in values.enumerated() {
            let height = range.span == 0
                ? rect.height * 0.4
                : rect.height * CGFloat((value - range.min) / range.span)
            let x = rect.minX + CGFloat(index) * (width + gap)
            path.addRoundedRect(
                in: CGRect(x: x, y: rect.maxY - max(1, height), width: width, height: max(1, height)),
                cornerSize: CGSize(width: 1.5, height: 1.5)
            )
        }
        return path
    }
}

private enum ChartScaling {
    static func range(_ values: [Double]) -> (min: Double, span: Double) {
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        return (minValue, maxValue - minValue)
    }

    static func points(values: [Double], in rect: CGRect) -> [CGPoint] {
        guard values.count > 1 else {
            return [CGPoint(x: rect.midX, y: rect.midY)]
        }
        let range = range(values)
        let step = rect.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let y = range.span == 0
                ? rect.midY
                : rect.maxY - CGFloat((value - range.min) / range.span) * rect.height
            return CGPoint(x: rect.minX + CGFloat(index) * step, y: y)
        }
    }
}

extension Color {
    /// Accepts `#rgb`, `#rrggbb`, `#rrggbbaa` or a handful of names.
    init(scriptValue: String) {
        let named: [String: Color] = [
            "white": .white, "black": .black, "red": .red, "orange": .orange,
            "yellow": .yellow, "green": .green, "mint": .mint, "teal": .teal,
            "blue": .blue, "indigo": .indigo, "purple": .purple, "pink": .pink,
            "gray": .gray, "grey": .gray,
        ]
        if let match = named[scriptValue.lowercased()] {
            self = match
            return
        }

        var hex = scriptValue.trimmingCharacters(in: .whitespaces)
        hex.removeFirst(hex.hasPrefix("#") ? 1 : 0)
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
            self = .white
            return
        }

        let hasAlpha = hex.count == 8
        let shift = hasAlpha ? 8 : 0
        self = Color(
            .sRGB,
            red: Double((value >> (16 + shift)) & 0xFF) / 255,
            green: Double((value >> (8 + shift)) & 0xFF) / 255,
            blue: Double((value >> shift) & 0xFF) / 255,
            opacity: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }
}
