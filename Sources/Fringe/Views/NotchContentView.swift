import SwiftUI

/// Everything inside the expanded panel. This is the file to edit — the window,
/// placement and hover machinery do not care what you put here.
struct NotchContentView: View {
    let state: NotchState
    let settings: NotchSettings
    let library: ScriptLibrary
    let nowPlaying: NowPlayingController
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NotchHeaderView(
                state: state,
                settings: settings,
                isEditing: state.isEditing,
                overflow: BoardArrangement(settings: settings, library: library).unplaced.map(\.name),
                onToggleEditing: toggleEditing,
                onOpenSettings: onOpenSettings
            )

            board
                .padding(.top, settings.contentTopPadding)
                .padding(.horizontal, settings.contentHorizontalPadding)
                .padding(.bottom, settings.contentBottomPadding)
        }
        .foregroundStyle(.white)
        .overlay {
            if state.isEditing {
                panelGrip.transition(.opacity)
            }
        }
    }

    private func toggleEditing() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            state.isEditing.toggle()
        }
        if !state.isEditing {
            state.arrange = nil
            state.hoveredWidget = nil
            state.hoveredGrip = nil
            state.hoveredRemove = nil
            state.hoveredPanelGrip = false
            state.panelResize = nil
        }
    }

    /// Same mark as a tile's resize corner, on the silhouette itself. The
    /// window controller owns the drag; this is only the drawing.
    private var panelGrip: some View {
        let active = state.hoveredPanelGrip || state.panelResize != nil
        return CornerGrip(
            cornerRadius: settings.expandedBottomRadius,
            lineWidth: active ? 5 : 3.5,
            extent: active ? 14 : 11
        )
        .stroke(
            .white.opacity(active ? 0.95 : 0.4),
            style: StrokeStyle(lineWidth: active ? 5 : 3.5, lineCap: .round)
        )
        .allowsHitTesting(false)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: active)
    }

    /// Widgets come from the `.js` files in the scripts folder. Each claims whole
    /// cells via `widgetSpan`, and the grid packs them in reading order.
    private var board: some View {
        let arrangement = BoardArrangement(
            settings: settings,
            library: library,
            proposal: dropProposal
        )
        let grid = arrangement.grid

        return ZStack(alignment: .topLeading) {
            // Only while arranging: the empty cells are scaffolding for
            // dropping things into, not decoration.
            if state.isEditing {
                WidgetGridBackground(grid: grid, occupied: arrangement.occupiedCells())
                    .transition(.opacity)
            }

            if state.isEditing, let pad = dropPad {
                DropTargetPad(grid: grid, placement: pad)
                    .transition(.opacity)
            }

            ForEach(arrangement.widgets) { widget in
                if let placement = arrangement.placements[widget.id] {
                    let frame = grid.rect(for: placement)
                    tile(for: widget, placement: placement)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(width: grid.contentSize.width, height: grid.contentSize.height, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .animation(
            state.arrange == nil ? nil : .spring(response: 0.32, dampingFraction: 0.82),
            value: arrangement.placements
        )
    }

    /// Where packing should pretend the dragged widget already sits, so the
    /// rest of the board can slide into the holes that drop will make.
    private var dropProposal: BoardProposal? {
        guard let session = state.arrange, !session.isSettling else { return nil }
        if session.kind == .move, session.isRemoving { return .hiding(id: session.widgetID) }
        guard let landing = session.landing else { return nil }
        return .moving(id: session.widgetID, to: landing)
    }

    private var dropPad: WidgetPlacement? {
        guard let session = state.arrange,
              session.kind == .move,
              !session.isSettling,
              !session.isRemoving
        else { return nil }
        return session.landing
    }

    private func tile(for widget: ScriptedWidget, placement: WidgetPlacement?) -> some View {
        let session = state.arrange
        let isThisMove = session?.widgetID == widget.id && session?.kind == .move
        // Live drag is drawn in a follow-cursor panel so it can leave the
        // clipped silhouette. The in-grid copy only comes back to spring
        // into its cell after a drop that stayed on the board.
        let isLiveDrag = isThisMove && session?.isSettling != true
        let isPlaceSettle = isThisMove && session?.isSettling == true && session?.isRemoving != true
        let isHovered = state.isEditing && state.hoveredWidget == widget.id && !isThisMove
        let isGripped = state.isEditing && state.hoveredGrip == widget.id && !isThisMove
        let isBadged = state.isEditing && state.hoveredRemove == widget.id && !isThisMove
        let isResizing = session?.widgetID == widget.id && session?.kind == .resize
        let showGrip = (isHovered || isGripped || isResizing) && !isLiveDrag

        return ScriptedWidgetView(
            widget: widget,
            span: placement?.span ?? widget.span,
            context: WidgetRenderContext.nowPlaying(
                nowPlaying,
                artwork: widget.permissions.media,
                isInteractive: !state.isEditing,
                perform: { [weak nowPlaying, weak widget] action in
                    switch action {
                    case "playPause", "next", "previous":
                        guard widget?.permissions.media == true else { return }
                        nowPlaying?.perform(action)
                    default:
                        widget?.handleAction(action)
                    }
                }
            )
        )
            .opacity(isLiveDrag ? 0 : (isPlaceSettle ? 0.85 : 1))
            .scaleEffect(isPlaceSettle ? 1.04 : (isHovered ? 1.02 : 1))
            .shadow(
                color: .black.opacity(isPlaceSettle ? 0.45 : (isHovered ? 0.25 : 0)),
                radius: isPlaceSettle ? 12 : 8,
                y: isPlaceSettle ? 6 : 3
            )
            .overlay {
                if state.isEditing {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            .white.opacity(0.16),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                }
            }
            .overlay {
                if showGrip {
                    CornerGrip(
                        cornerRadius: 14,
                        lineWidth: isGripped || isResizing ? 5 : 4,
                        extent: isGripped || isResizing ? 13 : 9
                    )
                    .stroke(
                        .white.opacity(isGripped || isResizing ? 1 : 0.75),
                        style: StrokeStyle(
                            lineWidth: isGripped || isResizing ? 5 : 4,
                            lineCap: .round
                        )
                    )
                    .scaleEffect(isGripped || isResizing ? 1.04 : 1, anchor: .bottomTrailing)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if state.isEditing, !isLiveDrag {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black.opacity(0.8), Color.white)
                        .font(.system(size: 15, weight: .bold))
                        .padding(3)
                        .scaleEffect(isBadged ? 1.12 : 1)
                        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isBadged)
                }
            }
            .offset(isPlaceSettle ? session?.translation ?? .zero : .zero)
            .zIndex(isPlaceSettle ? 1 : 0)
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: isHovered)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isGripped)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: showGrip)
            .animation(.easeOut(duration: 0.14), value: isPlaceSettle)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            // No gestures: pointer handling for the board lives in
            // NotchWindowController.
            .allowsHitTesting(!state.isEditing)
    }
}

/// Traces the tile's bottom-right corner, the way macOS marks a resizable
/// edge — a stroke following the radius rather than a button floating on top
/// of the content.
private struct CornerGrip: Shape {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat
    var extent: CGFloat

    func path(in rect: CGRect) -> Path {
        // Inset by half the stroke so it sits inside the tile instead of
        // straddling the edge.
        let bounds = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = max(0, cornerRadius - lineWidth / 2)

        var path = Path()
        path.move(to: CGPoint(x: bounds.maxX - radius - extent, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.maxX - radius, y: bounds.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX, y: bounds.maxY - radius),
            control: CGPoint(x: bounds.maxX, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - radius - extent))
        return path
    }
}

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
        .animation(.smooth(duration: 0.3), value: widget.node)
        .animation(.easeInOut(duration: 0.35), value: context.artworkID)
        // The ticker only asks scripts to render on their refresh interval.
        // A resize has to take effect on the same frame the cell changes,
        // otherwise a 2-row player stays stacked inside a 1-row tile.
        .onChange(of: span) { _, _ in
            widget.renderIfNeeded()
        }
    }
}

/// The band level with the notch itself. The middle is left empty for the cutout,
/// which on a real display is a hole in the panel — anything drawn there is
/// physically invisible.
private struct NotchHeaderView: View {
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
