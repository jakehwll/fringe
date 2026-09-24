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
        return .moving(id: session.widgetID, placement: landing)
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
            snapsLayout: isResizing,
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
            .overlay { editOutline }
            .overlay { gripMark(show: showGrip, active: isGripped || isResizing) }
            .overlay(alignment: .topLeading) { removeBadge(show: state.isEditing && !isLiveDrag, pressed: isBadged) }
            .offset(isPlaceSettle ? session?.translation ?? .zero : .zero)
            .zIndex(isPlaceSettle ? 1 : 0)
            // The cell the pointer just committed snaps with its tree.
            // Neighbours still spring via the board's placement animation.
            .transaction { transaction in
                if isResizing { transaction.disablesAnimations = true }
            }
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: isHovered)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isGripped)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: showGrip)
            .animation(.easeOut(duration: 0.14), value: isPlaceSettle)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            // No gestures: pointer handling for the board lives in
            // NotchWindowController.
            .allowsHitTesting(!state.isEditing)
    }

    @ViewBuilder
    private var editOutline: some View {
        if state.isEditing {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    .white.opacity(0.16),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
    }

    @ViewBuilder
    private func gripMark(show: Bool, active: Bool) -> some View {
        if show {
            CornerGrip(
                cornerRadius: 14,
                lineWidth: active ? 5 : 4,
                extent: active ? 13 : 9
            )
            .stroke(
                .white.opacity(active ? 1 : 0.75),
                style: StrokeStyle(lineWidth: active ? 5 : 4, lineCap: .round)
            )
            .scaleEffect(active ? 1.04 : 1, anchor: .bottomTrailing)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func removeBadge(show: Bool, pressed: Bool) -> some View {
        if show {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black.opacity(0.8), Color.white)
                .font(.system(size: 15, weight: .bold))
                .padding(3)
                .scaleEffect(pressed ? 1.12 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
        }
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
