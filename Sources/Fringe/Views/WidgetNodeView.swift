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
                action: { context.perform(button.action) },
                content: { WidgetNodeView(node: button.child, context: context) }
            )

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
