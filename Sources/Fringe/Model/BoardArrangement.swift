import CoreGraphics

/// Where every widget currently sits.
///
/// Built from settings and the library alone, so the window controller can
/// hit-test a drag against exactly the cells the view is drawing — the two
/// cannot disagree about where a widget is.
@MainActor
struct BoardArrangement {
    let grid: NotchGrid

    /// Enabled widgets that found a cell. Only these are rendered — a widget
    /// with no placement used to be laid out at the origin with a zero-size
    /// proposal, which does not hide it, it just makes it overlap whatever is
    /// in the corner.
    let widgets: [ScriptedWidget]

    /// Enabled but with nowhere to go: the grid is too small, or its
    /// neighbours have taken the room.
    let unplaced: [ScriptedWidget]

    /// Switched off in settings.
    let disabled: [ScriptedWidget]

    let placements: [String: WidgetPlacement]

    /// Side of the square at a tile's bottom-right corner that resizes it.
    static let gripSize: CGFloat = 26

    /// Hit target for the minus badge at a tile's top-left.
    static let badgeSize: CGFloat = 22

    init(
        settings: NotchSettings,
        library: ScriptLibrary,
        proposal: BoardProposal? = nil
    ) {
        grid = settings.grid

        let all = library.widgets(orderedBy: settings.widgetOrder)
        let enabled = all.filter { settings.isEnabled($0.id) }
        disabled = all.filter { !settings.isEnabled($0.id) }

        var requests = enabled.map {
            WidgetArrangementRequest(
                id: $0.id,
                span: settings.span(for: $0.id, declared: $0.span),
                preferred: settings.position(for: $0.id)
            )
        }
        switch proposal {
        case .moving(let id, let placement):
            requests = NotchGrid.relocate(requests, moving: id, to: placement)
        case .hiding(let id):
            requests = requests.filter { $0.id != id }
        case nil:
            break
        }

        // Bound locally first: referring to the stored property inside the
        // filters below would capture a half-initialised `self`.
        let resolved = grid.arrange(requests)
        placements = resolved

        widgets = enabled.filter { resolved[$0.id] != nil }
        unplaced = enabled.filter { widget in
            resolved[widget.id] == nil && proposal?.hiddenID != widget.id
        }
    }

    /// Placements without the scripts that produced them.
    ///
    /// Answering "what is under this point" needs a grid and some rectangles,
    /// not a JavaScript runtime — and requiring one is what would otherwise
    /// make the hit-testing untestable.
    init(grid: NotchGrid, placements: [String: WidgetPlacement]) {
        self.grid = grid
        self.placements = placements
        widgets = []
        unplaced = []
        disabled = []
    }

    func rect(of id: String) -> CGRect? {
        placements[id].map(grid.rect(for:))
    }

    func widget(at point: CGPoint) -> String? {
        placements.first { grid.rect(for: $0.value).contains(point) }?.key
    }

    /// The widget whose resize corner contains this point, if any. Checked
    /// before `widget(at:)` so the corner wins over the body beneath it.
    func grip(at point: CGPoint) -> String? {
        placements.first { _, placement in
            let rect = grid.rect(for: placement)
            let corner = CGRect(
                x: rect.maxX - Self.gripSize,
                y: rect.maxY - Self.gripSize,
                width: Self.gripSize,
                height: Self.gripSize
            )
            return corner.contains(point)
        }?.key
    }

    /// The widget whose minus badge contains this point. Top-left of the
    /// tile, checked before a move so tapping it cannot pick the widget up.
    func removeBadge(at point: CGPoint) -> String? {
        placements.first { _, placement in
            let rect = grid.rect(for: placement)
            let badge = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: Self.badgeSize,
                height: Self.badgeSize
            )
            return badge.contains(point)
        }?.key
    }

    /// Cells occupied by anything, for dimming the empty ones.
    func occupiedCells() -> Set<Int> {
        var cells: Set<Int> = []
        for placement in placements.values {
            for row in placement.slot.row..<(placement.slot.row + placement.span.rows) {
                for column in placement.slot.column..<(placement.slot.column + placement.span.columns) {
                    cells.insert(row * grid.columns + column)
                }
            }
        }
        return cells
    }
}

/// Live drop the board is previewing. Packing uses this instead of the
/// stored pin so neighbours can slide into the holes a drag is about to make.
enum BoardProposal: Equatable {
    case moving(id: String, to: WidgetPlacement)
    /// Off the panel; dropping will hide it.
    case hiding(id: String)

    var hiddenID: String? {
        if case .hiding(let id) = self { return id }
        return nil
    }
}
