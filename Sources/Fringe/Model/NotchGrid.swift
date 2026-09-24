import CoreGraphics

/// How many grid cells a widget takes up. Widgets are sized in cells, never in
/// points — a `.wide` widget is two cells across on every display and at every
/// cell size.
struct WidgetSpan: Equatable, Hashable {
    var columns: Int
    var rows: Int

    static let small = WidgetSpan(columns: 1, rows: 1)
    static let wide = WidgetSpan(columns: 2, rows: 1)
    static let tall = WidgetSpan(columns: 1, rows: 2)
    static let large = WidgetSpan(columns: 2, rows: 2)
}

/// A board of square cells. The panel's point size is derived from this, rather
/// than the other way around.
struct NotchGrid: Equatable {
    var columns: Int
    var rows: Int
    var cellSize: CGFloat
    var spacing: CGFloat

    var contentSize: CGSize {
        CGSize(width: length(cells: columns), height: length(cells: rows))
    }

    /// Point length of a run of `cells` cells, including the gutters between them.
    func length(cells: Int) -> CGFloat {
        guard cells > 0 else { return 0 }
        return CGFloat(cells) * cellSize + CGFloat(cells - 1) * spacing
    }

    func rect(column: Int, row: Int, span: WidgetSpan, in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + CGFloat(column) * (cellSize + spacing),
            y: bounds.minY + CGFloat(row) * (cellSize + spacing),
            width: length(cells: span.columns),
            height: length(cells: span.rows)
        )
    }

    /// Runs the same packing the layout uses and reports where each span
    /// landed, so a drag can be hit-tested against the cells actually on
    /// screen. `nil` for anything that did not fit.
    func placements(for spans: [WidgetSpan]) -> [CGRect?] {
        var occupancy = GridOccupancy(columns: columns, rows: rows)
        let bounds = CGRect(origin: .zero, size: contentSize)

        return spans.map { span in
            let span = clamped(span)
            guard let slot = occupancy.claim(span) else { return nil }
            return rect(column: slot.column, row: slot.row, span: span, in: bounds)
        }
    }

    /// Cell whose rect contains this point, truncated into the grid.
    ///
    /// Truncation, not rounding: a point in the gutter still belongs to the
    /// cell on its left, which is what "which tile am I over" means. Dropping
    /// a dragged tile uses `slot(snapping:span:)` instead — that *does* round,
    /// so a tile that has crossed the midpoint of a gutter lands in the next
    /// cell rather than sticking until it fully enters it.
    func cell(containing point: CGPoint) -> GridSlot {
        let stride = cellSize + spacing
        return GridSlot(
            column: min(max(0, Int(point.x / stride)), max(0, columns - 1)),
            row: min(max(0, Int(point.y / stride)), max(0, rows - 1))
        )
    }

    /// Nearest cell a dragged tile of `span` should occupy, given the point
    /// its origin has been dragged to.
    ///
    /// Rounding at half a stride is the whole behaviour: without it a tile
    /// has to be dragged almost a full cell before it commits, which is what
    /// made dropping feel like it lagged the pointer.
    func slot(snapping origin: CGPoint, span: WidgetSpan) -> GridSlot {
        let stride = cellSize + spacing
        return clampSlot(
            GridSlot(
                column: Int((origin.x / stride).rounded()),
                row: Int((origin.y / stride).rounded())
            ),
            span: span
        )
    }

    /// `span` grown by a pointer translation, still a whole number of cells
    /// and still on the board. Same rounding rule as `slot(snapping:span:)`.
    func span(_ span: WidgetSpan, grownBy translation: CGSize) -> WidgetSpan {
        let stride = cellSize + spacing
        return clamped(
            WidgetSpan(
                columns: span.columns + Int((translation.width / stride).rounded()),
                rows: span.rows + Int((translation.height / stride).rounded())
            )
        )
    }

    /// Grid size after dragging the panel's bottom-right corner.
    ///
    /// Columns grow from both sides (the silhouette stays centred on the
    /// notch), so a column is added when the pointer has moved *half* a
    /// stride — that is how far the dragged edge actually travels. Rows
    /// only grow downward, so they still use a full stride.
    func grown(
        from columns: Int,
        rows: Int,
        by translation: CGSize,
        columnRange: ClosedRange<Int>,
        rowRange: ClosedRange<Int>
    ) -> (columns: Int, rows: Int) {
        let stride = cellSize + spacing
        let columnDelta = Int((translation.width / (stride / 2)).rounded())
        let rowDelta = Int((translation.height / stride).rounded())
        return (
            columnRange.clamping(columns + columnDelta),
            rowRange.clamping(rows + rowDelta)
        )
    }

    /// A span trimmed to fit, but never below one whole cell.
    ///
    /// The lower bound is not decoration. On a board with no cells this would
    /// otherwise return a zero-sized span, which `GridOccupancy` happily
    /// "places" at the origin because a zero-sized region trivially fits
    /// anywhere — putting an invisible widget on top of the corner instead of
    /// reporting it as unplaced.
    func clamped(_ span: WidgetSpan) -> WidgetSpan {
        WidgetSpan(
            columns: min(max(1, span.columns), max(1, columns)),
            rows: min(max(1, span.rows), max(1, rows))
        )
    }
}

struct GridSlot: Equatable {
    var column: Int
    var row: Int
}

struct WidgetPlacement: Equatable {
    var slot: GridSlot
    var span: WidgetSpan

    func overlaps(_ other: WidgetPlacement) -> Bool {
        let columns = slot.column..<(slot.column + span.columns)
        let rows = slot.row..<(slot.row + span.rows)
        let otherColumns = other.slot.column..<(other.slot.column + other.span.columns)
        let otherRows = other.slot.row..<(other.slot.row + other.span.rows)
        return columns.overlaps(otherColumns) && rows.overlaps(otherRows)
    }
}

struct WidgetArrangementRequest {
    var id: String
    var span: WidgetSpan
    /// Cell the user put it in. Nil means "anywhere it fits".
    var preferred: GridSlot?
}

extension NotchGrid {
    /// Resolves the final cell for every widget.
    ///
    /// Anything the user positioned keeps its cell; everything else packs into
    /// whatever is left. Without this two-pass split, a packed layout can only
    /// ever fill from the top-left and gaps are impossible — which is exactly
    /// what stops a widget being dragged to the right-hand side.
    func arrange(_ requests: [WidgetArrangementRequest]) -> [String: WidgetPlacement] {
        var occupancy = GridOccupancy(columns: columns, rows: rows)
        var placements: [String: WidgetPlacement] = [:]
        var unplaced: [WidgetArrangementRequest] = []

        for request in requests {
            let span = clamped(request.span)
            guard let preferred = request.preferred,
                  occupancy.claim(span, at: preferred)
            else {
                unplaced.append(request)
                continue
            }
            placements[request.id] = WidgetPlacement(slot: preferred, span: span)
        }

        for request in unplaced {
            let span = clamped(request.span)
            guard let fitted = occupancy.claimFitting(span) else { continue }
            placements[request.id] = fitted
        }

        return placements
    }

    /// Same packing a drop uses, without writing it. The moved widget is
    /// pinned to `placement`; anyone overlapping that cell is unpinned and
    /// packed into whatever is left — which is how a live preview can show
    /// where neighbours will land before the mouse is up.
    static func relocate(
        _ requests: [WidgetArrangementRequest],
        moving id: String,
        to placement: WidgetPlacement
    ) -> [WidgetArrangementRequest] {
        requests.map { request in
            if request.id == id {
                return WidgetArrangementRequest(
                    id: id,
                    span: placement.span,
                    preferred: placement.slot
                )
            }
            guard let preferred = request.preferred else { return request }
            let occupied = WidgetPlacement(slot: preferred, span: request.span)
            guard occupied.overlaps(placement) else { return request }
            return WidgetArrangementRequest(id: request.id, span: request.span, preferred: nil)
        }
    }

    func rect(for placement: WidgetPlacement) -> CGRect {
        rect(
            column: placement.slot.column,
            row: placement.slot.row,
            span: placement.span,
            in: CGRect(origin: .zero, size: contentSize)
        )
    }

    /// Clamps a slot so a span of this size stays inside the grid.
    func clampSlot(_ slot: GridSlot, span: WidgetSpan) -> GridSlot {
        GridSlot(
            column: min(max(0, slot.column), max(0, columns - span.columns)),
            row: min(max(0, slot.row), max(0, rows - span.rows))
        )
    }
}

/// Tracks which cells are spoken for while widgets are placed.
struct GridOccupancy {
    private var taken: [[Bool]]
    private let columns: Int
    private let rows: Int

    init(columns: Int, rows: Int) {
        self.columns = max(0, columns)
        self.rows = max(0, rows)
        taken = Array(
            repeating: Array(repeating: false, count: self.columns),
            count: self.rows
        )
    }

    /// First free slot in reading order that fits `span`, marked as used.
    mutating func claim(_ span: WidgetSpan) -> (column: Int, row: Int)? {
        guard span.columns <= columns, span.rows <= rows else { return nil }

        for row in 0...(rows - span.rows) {
            for column in 0...(columns - span.columns) where isFree(column, row, span) {
                fill(column, row, span)
                return (column, row)
            }
        }
        return nil
    }

    /// Next safe cell for this span. Keeps the declared size when it fits;
    /// otherwise shrinks (a 1-row strip first, then down to 1×1) rather than
    /// overlapping or vanishing. Nil only when the board has no free cell.
    mutating func claimFitting(_ span: WidgetSpan) -> WidgetPlacement? {
        for candidate in Self.fitOrder(span) {
            guard let slot = claim(candidate) else { continue }
            return WidgetPlacement(
                slot: GridSlot(column: slot.column, row: slot.row),
                span: candidate
            )
        }
        return nil
    }

    /// Declared size, then a 1-row strip at that width (the compact layout
    /// scripts already handle), then every smaller size so a 3×2 can still
    /// take a 2×1 hole.
    static func fitOrder(_ span: WidgetSpan) -> [WidgetSpan] {
        var seen: Set<WidgetSpan> = []
        var order: [WidgetSpan] = []
        func add(_ next: WidgetSpan) {
            let next = WidgetSpan(columns: max(1, next.columns), rows: max(1, next.rows))
            if seen.insert(next).inserted { order.append(next) }
        }
        add(span)
        add(WidgetSpan(columns: span.columns, rows: 1))
        for rows in stride(from: span.rows, through: 1, by: -1) {
            for cols in stride(from: span.columns, through: 1, by: -1) {
                add(WidgetSpan(columns: cols, rows: rows))
            }
        }
        return order
    }

    /// Claims an exact slot, or reports that it is taken or out of bounds.
    mutating func claim(_ span: WidgetSpan, at slot: GridSlot) -> Bool {
        guard slot.column >= 0, slot.row >= 0,
              slot.column + span.columns <= columns,
              slot.row + span.rows <= rows,
              isFree(slot.column, slot.row, span)
        else { return false }

        fill(slot.column, slot.row, span)
        return true
    }

    private func isFree(_ column: Int, _ row: Int, _ span: WidgetSpan) -> Bool {
        for rowIndex in row..<(row + span.rows) {
            for columnIndex in column..<(column + span.columns) where taken[rowIndex][columnIndex] {
                return false
            }
        }
        return true
    }

    private mutating func fill(_ column: Int, _ row: Int, _ span: WidgetSpan) {
        for rowIndex in row..<(row + span.rows) {
            for columnIndex in column..<(column + span.columns) {
                taken[rowIndex][columnIndex] = true
            }
        }
    }
}
