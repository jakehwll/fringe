import SwiftUI

/// Lifted copy of a tile that follows the cursor in its own panel, so it can
/// travel off the clipped notch silhouette. Dropping while `isRemoving` hides
/// the widget the way dragging an icon off the Dock does.
struct WidgetDragPreview: View {
    let state: NotchState
    let library: ScriptLibrary
    let nowPlaying: NowPlayingController

    /// Transparent margin around the tile so scale and shadow are not clipped
    /// by the preview panel. The window is grown by the same amount.
    static let margin: CGFloat = 28

    var body: some View {
        if let session = state.arrange, session.kind == .move,
           let widget = library.widgets.first(where: { $0.id == session.widgetID }) {
            let poof = session.isSettling && session.isRemoving
            ScriptedWidgetView(
                widget: widget,
                span: session.baseSpan,
                context: .nowPlaying(nowPlaying, artwork: widget.permissions.media)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        .white.opacity(session.isRemoving ? 0.45 : 0.16),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            .compositingGroup()
            .scaleEffect(poof ? 0.12 : (session.isRemoving ? 0.9 : 1.05))
            .opacity(poof ? 0 : (session.isRemoving ? 0.72 : 0.95))
            .shadow(
                color: .black.opacity(session.isRemoving ? 0.2 : 0.5),
                radius: session.isRemoving ? 8 : 16,
                y: session.isRemoving ? 4 : 8
            )
            .padding(Self.margin)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: session.isRemoving)
            .animation(.easeIn(duration: 0.16), value: poof)
        }
    }
}

struct ScriptedWidgetView: View {
    let widget: ScriptedWidget
    var span: WidgetSpan = .small
    /// Tile is mid-resize: skip the tree fade so a layout swap is not
    /// interpolated on top of the cell snap.
    var snapsLayout = false
    var context: WidgetRenderContext = .inert

    var body: some View {
        WidgetTile {
            if let failure = widget.failure {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                    Text(widget.name)
                        .font(.system(size: 10, weight: .medium))
                    Text(failure)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
                .padding(6)
            } else if let node = widget.node {
                // The script's own inset. A widget drawing a full-bleed
                // backdrop sets it to zero and pads its contents instead —
                // a fixed inset here would strand its background short of the
                // tile edge while empty cells fill theirs.
                WidgetNodeView(node: node, context: context)
                    .padding(widget.padding)
            }
        }
        // The tile is already the cell; this only rounds it. Hit-testing has
        // to match, or a clipped script still eats clicks in the overflow.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // `WidgetNode` is Equatable, so animating on the tree itself covers
        // every change a script can make — text, layout, spans — in one place.
        // Resize snaps: morphing a 2-row player into a strip is the jank.
        .animation(snapsLayout ? nil : .smooth(duration: 0.3), value: widget.node)
        .animation(.easeInOut(duration: 0.35), value: context.artworkID)
        // The ticker only asks scripts to render on their refresh interval.
        // A resize has to take effect on the same frame the cell changes,
        // otherwise a 2-row player stays stacked inside a 1-row tile.
        // `initial` covers a packed fit on first appear, before any tick.
        .onChange(of: span, initial: true) { _, newSpan in
            widget.renderIfNeeded(span: newSpan)
        }
    }
}

/// The band level with the notch itself. The middle is left empty for the cutout,
/// which on a real display is a hole in the panel — anything drawn there is
/// physically invisible.
struct NotchHeaderView: View {
    let state: NotchState
    let settings: NotchSettings
    let isEditing: Bool
    var overflow: [String] = []
    let onToggleEditing: () -> Void
    let onOpenSettings: () -> Void

    /// Width of the usable strip on each side of the cutout.
    private var sideWidth: CGFloat {
        let panelWidth = settings.expandedSize(notch: state.metrics.size).width
        return max(0, (panelWidth - state.metrics.size.width) / 2)
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: sideWidth)
                .allowsHitTesting(false)

            Color.clear
                .frame(width: state.metrics.size.width)
                .allowsHitTesting(false)

            HStack(spacing: 2) {
                if !overflow.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help(overflow.joined(separator: ", ") + " — no room on the grid")
                        .frame(width: 28, height: 28)
                }
                NotchIconButton(
                    systemName: isEditing ? "checkmark" : "pencil",
                    isActive: isEditing,
                    action: onToggleEditing
                )
                NotchIconButton(
                    systemName: "gearshape.fill",
                    spinsOnHover: true,
                    action: onOpenSettings
                )
            }
            .padding(.trailing, settings.headerHorizontalPadding)
            .frame(width: sideWidth, alignment: .trailing)
        }
        .frame(height: state.metrics.size.height)
    }
}

private struct NotchIconButton: View {
    let systemName: String
    var isActive = false
    var spinsOnHover = false
    let action: () -> Void

    @State private var isHovering = false

    private var opacity: Double {
        if isActive { return 1 }
        return isHovering ? 0.95 : 0.55
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(opacity))
            .rotationEffect(.degrees(spinsOnHover && isHovering ? 45 : 0))
            .frame(width: 28, height: 28)
            .background(Circle().fill(.white.opacity(isActive ? 0.2 : (isHovering ? 0.12 : 0))))
            .contentShape(Circle())
            // A SwiftUI `Button` inside a `.nonactivatingPanel` often never
            // sees the click, because the panel does not become key. A tap
            // gesture does.
            .onTapGesture(perform: action)
            .onHover { isHovering = $0 }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHovering)
    }
}
