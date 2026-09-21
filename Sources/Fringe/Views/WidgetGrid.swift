import SwiftUI

private struct WidgetPlacementKey: LayoutValueKey {
    static let defaultValue: WidgetPlacement? = nil
}

extension View {
    /// The cell this widget occupies. Resolved up front by `NotchGrid.arrange`
    /// rather than by the layout, so the same answer is available for
    /// hit-testing a drag.
    func widgetPlacement(_ placement: WidgetPlacement?) -> some View {
        layoutValue(key: WidgetPlacementKey.self, value: placement)
    }
}

/// Places widgets at the cells they were already assigned. Anything without a
/// placement did not fit and is collapsed away rather than overlapping.
struct WidgetGridLayout: Layout {
    let grid: NotchGrid

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        grid.contentSize
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        for subview in subviews {
            guard let placement = subview[WidgetPlacementKey.self] else {
                subview.place(at: bounds.origin, proposal: ProposedViewSize(.zero))
                continue
            }

            let frame = grid.rect(for: placement).offsetBy(dx: bounds.minX, dy: bounds.minY)
            subview.place(
                at: frame.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

/// Quiet fills for cells that nothing claimed. Occupied slots stay bare — the
/// widget is the cell, so a second rounded rect behind it just doubles up.
struct WidgetGridBackground: View {
    let grid: NotchGrid
    var occupied: Set<Int> = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<max(0, grid.rows), id: \.self) { row in
                ForEach(0..<max(0, grid.columns), id: \.self) { column in
                    if !occupied.contains(row * grid.columns + column) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.06))
                            .frame(width: grid.cellSize, height: grid.cellSize)
                            .offset(
                                x: CGFloat(column) * (grid.cellSize + grid.spacing),
                                y: CGFloat(row) * (grid.cellSize + grid.spacing)
                            )
                    }
                }
            }
        }
        .frame(width: grid.contentSize.width, height: grid.contentSize.height, alignment: .topLeading)
    }
}

/// Hole the dragged (or resized) widget will occupy. Neighbours have already
/// packed around it; this is the empty cell the pointer is offering.
struct DropTargetPad: View {
    let grid: NotchGrid
    let placement: WidgetPlacement

    var body: some View {
        let rect = grid.rect(for: placement)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        .white.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                    )
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}

/// Positions content in the cell the grid assigned. No card of its own —
/// widgets with content should not sit on a second rounded rectangle.
///
/// `Color.clear` is what actually sizes the tile: it takes the cell the
/// layout proposed. Framing the script's tree with `maxWidth: .infinity`
/// instead lets the tree's own minimum win, which is how a 1-wide player
/// with a long title ended up drawing wider than the 3-wide default — and
/// why `clipShape` on that oversized frame never clipped to the cell.
struct WidgetTile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Color.clear
            .overlay {
                content
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
            .clipped()
            .contentShape(Rectangle())
    }
}
