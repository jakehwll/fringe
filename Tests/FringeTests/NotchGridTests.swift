import CoreGraphics
import Testing

@testable import Fringe

/// A 6×2 board of 72pt cells with 12pt gutters — the shipping default.
private let board = NotchGrid(columns: 6, rows: 2, cellSize: 72, spacing: 12)

@Suite("Grid measurement")
struct GridMeasurementTests {
    @Test("A run of cells includes the gutters between them, not around them")
    func runLength() {
        #expect(board.length(cells: 0) == 0)
        #expect(board.length(cells: 1) == 72)
        #expect(board.length(cells: 2) == 156) // 72 + 12 + 72
        #expect(board.length(cells: 3) == 240)
    }

    @Test("Content size is the full run in both axes")
    func contentSize() {
        #expect(board.contentSize == CGSize(width: 492, height: 156))
    }

    @Test("A cell's rect is offset by whole cells plus gutters")
    func cellRect() {
        let rect = board.rect(
            column: 2,
            row: 1,
            span: .small,
            in: CGRect(origin: .zero, size: board.contentSize)
        )
        #expect(rect == CGRect(x: 168, y: 84, width: 72, height: 72))
    }

    @Test("A spanning tile swallows the gutters it covers")
    func spanningRect() {
        let rect = board.rect(
            column: 0,
            row: 0,
            span: .large,
            in: CGRect(origin: .zero, size: board.contentSize)
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 156, height: 156))
    }

    @Test("Rects are offset by the bounds they are placed in")
    func offsetByBounds() {
        let rect = board.rect(
            column: 0,
            row: 0,
            span: .small,
            in: CGRect(x: 100, y: 50, width: 492, height: 156)
        )
        #expect(rect.origin == CGPoint(x: 100, y: 50))
    }

    @Test("A span is clamped to the board, and never to nothing")
    func spanClamping() {
        #expect(board.clamped(WidgetSpan(columns: 99, rows: 99)) == WidgetSpan(columns: 6, rows: 2))
        #expect(board.clamped(WidgetSpan(columns: 0, rows: 0)) == WidgetSpan(columns: 1, rows: 1))
        #expect(board.clamped(WidgetSpan(columns: -3, rows: 1)) == WidgetSpan(columns: 1, rows: 1))
        #expect(board.clamped(.wide) == .wide)
    }

    @Test("A slot is clamped so its whole span stays on the board")
    func slotClamping() {
        // A 2-wide tile cannot start in the last column.
        #expect(board.clampSlot(GridSlot(column: 5, row: 0), span: .wide) == GridSlot(column: 4, row: 0))
        #expect(board.clampSlot(GridSlot(column: -1, row: -1), span: .small) == GridSlot(column: 0, row: 0))
        #expect(board.clampSlot(GridSlot(column: 0, row: 9), span: .tall) == GridSlot(column: 0, row: 0))
        #expect(board.clampSlot(GridSlot(column: 3, row: 1), span: .small) == GridSlot(column: 3, row: 1))
    }
}

@Suite("Point to cell")
struct PointToCellTests {
    /// 72pt cells, 12pt gutters — a stride of 84.
    private let stride: CGFloat = 84

    @Test("A point inside a cell belongs to that cell")
    func containingTruncates() {
        #expect(board.cell(containing: CGPoint(x: 10, y: 10)) == GridSlot(column: 0, row: 0))
        #expect(board.cell(containing: CGPoint(x: 83, y: 10)) == GridSlot(column: 0, row: 0))
        #expect(board.cell(containing: CGPoint(x: 84, y: 10)) == GridSlot(column: 1, row: 0))
        #expect(board.cell(containing: CGPoint(x: 10, y: 84)) == GridSlot(column: 0, row: 1))
    }

    @Test("A point in a gutter still belongs to the cell on its left")
    func gutterStaysWithPreviousCell() {
        // Column 0 ends at 72; column 1 starts at 84. The gutter is 72..<84.
        #expect(board.cell(containing: CGPoint(x: 72, y: 0)) == GridSlot(column: 0, row: 0))
        #expect(board.cell(containing: CGPoint(x: 83, y: 0)) == GridSlot(column: 0, row: 0))
    }

    @Test("Containing a point past the board clamps, it does not wrap")
    func containingClamps() {
        #expect(board.cell(containing: CGPoint(x: -10, y: -10)) == GridSlot(column: 0, row: 0))
        #expect(board.cell(containing: CGPoint(x: 9_000, y: 9_000)) == GridSlot(column: 5, row: 1))
    }

    /// Rounding at half a stride is the drop behaviour: a tile that has
    /// crossed the midpoint of a gutter commits to the next cell, rather
    /// than waiting until it is fully inside it.
    @Test("Snapping rounds at half a stride")
    func snappingRounds() {
        let half = stride / 2
        #expect(board.slot(snapping: CGPoint(x: half - 1, y: 0), span: .small) == GridSlot(column: 0, row: 0))
        #expect(board.slot(snapping: CGPoint(x: half, y: 0), span: .small) == GridSlot(column: 1, row: 0))
        #expect(board.slot(snapping: CGPoint(x: 0, y: half), span: .small) == GridSlot(column: 0, row: 1))
    }

    @Test("Snapping a wide tile near the right edge keeps it on the board")
    func snappingClampsWideSpans() {
        // Column 5 cannot host a 2-wide tile.
        #expect(board.slot(snapping: CGPoint(x: stride * 5, y: 0), span: .wide) == GridSlot(column: 4, row: 0))
        #expect(board.slot(snapping: CGPoint(x: -40, y: -40), span: .large) == GridSlot(column: 0, row: 0))
    }

    @Test("Resizing grows by whole cells and will not shrink below one")
    func resizeGrowsByCells() {
        #expect(board.span(.small, grownBy: CGSize(width: stride / 2 - 1, height: 0)) == .small)
        #expect(board.span(.small, grownBy: CGSize(width: stride / 2, height: 0)) == .wide)
        #expect(board.span(.small, grownBy: CGSize(width: -200, height: -200)) == .small)
        #expect(board.span(.small, grownBy: CGSize(width: 9_000, height: 9_000)) == WidgetSpan(columns: 6, rows: 2))
    }

    @Test("Panel resize adds a column at half a stride, a row at a full stride")
    func panelResizeCentredColumns() {
        let rangeC = 3...10
        let rangeR = 1...4
        let half = stride / 2

        #expect(board.grown(from: 6, rows: 2, by: .zero, columnRange: rangeC, rowRange: rangeR) == (6, 2))
        // The dragged edge only travels half a cell per column.
        #expect(board.grown(from: 6, rows: 2, by: CGSize(width: half / 2 - 1, height: 0), columnRange: rangeC, rowRange: rangeR) == (6, 2))
        #expect(board.grown(from: 6, rows: 2, by: CGSize(width: half / 2, height: 0), columnRange: rangeC, rowRange: rangeR) == (7, 2))
        #expect(board.grown(from: 6, rows: 2, by: CGSize(width: 0, height: half), columnRange: rangeC, rowRange: rangeR) == (6, 3))
        #expect(board.grown(from: 6, rows: 2, by: CGSize(width: -9_000, height: -9_000), columnRange: rangeC, rowRange: rangeR) == (3, 1))
        #expect(board.grown(from: 6, rows: 2, by: CGSize(width: 9_000, height: 9_000), columnRange: rangeC, rowRange: rangeR) == (10, 4))
    }
}

@Suite("Grid packing")
struct GridPackingTests {
    private func request(_ id: String, _ span: WidgetSpan, at slot: GridSlot? = nil) -> WidgetArrangementRequest {
        WidgetArrangementRequest(id: id, span: span, preferred: slot)
    }

    @Test("Unpositioned widgets pack in reading order")
    func packsInReadingOrder() {
        let placed = board.arrange([
            request("a", .small),
            request("b", .small),
            request("c", .small),
        ])

        #expect(placed["a"]?.slot == GridSlot(column: 0, row: 0))
        #expect(placed["b"]?.slot == GridSlot(column: 1, row: 0))
        #expect(placed["c"]?.slot == GridSlot(column: 2, row: 0))
    }

    @Test("Packing wraps to the next row when a row fills up")
    func wrapsRows() {
        let placed = board.arrange((0..<7).map { request("w\($0)", .small) })

        #expect(placed["w5"]?.slot == GridSlot(column: 5, row: 0))
        #expect(placed["w6"]?.slot == GridSlot(column: 0, row: 1))
    }

    @Test("A positioned widget keeps its cell even when it is not the first free one")
    func honoursExplicitPosition() {
        let placed = board.arrange([
            request("pinned", .small, at: GridSlot(column: 4, row: 1)),
            request("packed", .small),
        ])

        #expect(placed["pinned"]?.slot == GridSlot(column: 4, row: 1))
        #expect(placed["packed"]?.slot == GridSlot(column: 0, row: 0))
    }

    /// The two-pass split is the whole reason a widget can be dragged to the
    /// right-hand side: a single packing pass can only ever fill from the
    /// top-left, so gaps would be impossible.
    @Test("Packed widgets flow around positioned ones rather than displacing them")
    func packsAroundPinned() {
        let placed = board.arrange([
            request("packed", .small),
            request("pinned", .small, at: GridSlot(column: 1, row: 0)),
        ])

        #expect(placed["pinned"]?.slot == GridSlot(column: 1, row: 0))
        #expect(placed["packed"]?.slot == GridSlot(column: 0, row: 0))
    }

    @Test("Order of requests does not change where a positioned widget lands")
    func pinningIsOrderIndependent() {
        let pinnedFirst = board.arrange([
            request("pinned", .small, at: GridSlot(column: 3, row: 0)),
            request("a", .small),
            request("b", .small),
        ])
        let pinnedLast = board.arrange([
            request("a", .small),
            request("b", .small),
            request("pinned", .small, at: GridSlot(column: 3, row: 0)),
        ])

        #expect(pinnedFirst == pinnedLast)
    }

    @Test("A widget that does not fit is left unplaced rather than overlapping")
    func overflowIsUnplaced() {
        // Twelve 1×1 cells exist; the thirteenth has nowhere to go.
        let placed = board.arrange((0..<13).map { request("w\($0)", .small) })

        #expect(placed.count == 12)
        #expect(placed["w12"] == nil)
    }

    @Test("A span that cannot fit shrinks into the next free cells")
    func overflowShrinksToFit() {
        let placed = board.arrange([
            request("full", WidgetSpan(columns: 5, rows: 2)),
            request("player", WidgetSpan(columns: 3, rows: 2)),
        ])

        #expect(placed["full"]?.span == WidgetSpan(columns: 5, rows: 2))
        #expect(placed["player"]?.slot == GridSlot(column: 5, row: 0))
        #expect(placed["player"]?.span == WidgetSpan(columns: 1, rows: 2))
    }

    @Test("A fitted span pinned to its cell stays there on the next arrange")
    func fittedPinSticks() {
        let first = board.arrange([
            request("full", WidgetSpan(columns: 5, rows: 2)),
            request("player", WidgetSpan(columns: 3, rows: 2)),
        ])
        let fitted = first["player"]!

        let again = board.arrange([
            request("full", WidgetSpan(columns: 5, rows: 2), at: GridSlot(column: 0, row: 0)),
            request("player", fitted.span, at: fitted.slot),
        ])

        #expect(again["player"]?.slot == fitted.slot)
        #expect(again["player"]?.span == fitted.span)
    }

    @Test("Pinning the declared span at a fitted cell misses and reflows")
    func declaredPinAtFittedCellMisses() {
        let first = board.arrange([
            request("full", WidgetSpan(columns: 5, rows: 2)),
            request("player", WidgetSpan(columns: 3, rows: 2)),
        ])
        let fitted = first["player"]!

        let bounced = board.arrange([
            request("full", WidgetSpan(columns: 5, rows: 2), at: GridSlot(column: 0, row: 0)),
            request("player", WidgetSpan(columns: 3, rows: 2), at: fitted.slot),
        ])

        #expect(bounced["player"]?.span != WidgetSpan(columns: 3, rows: 2))
    }

    @Test("A 1-row strip is preferred to jumping straight to 1×1")
    func overflowPrefersStrip() {
        let placed = board.arrange([
            request("a", .small, at: GridSlot(column: 0, row: 1)),
            request("b", .small, at: GridSlot(column: 2, row: 1)),
            request("c", .small, at: GridSlot(column: 4, row: 1)),
            request("player", WidgetSpan(columns: 3, rows: 2)),
        ])

        #expect(placed["player"]?.span == WidgetSpan(columns: 3, rows: 1))
        #expect(placed["player"]?.slot == GridSlot(column: 0, row: 0))
    }

    @Test("A span too large for the board is clamped, not dropped")
    func oversizedSpanIsClamped() {
        let placed = board.arrange([request("huge", WidgetSpan(columns: 99, rows: 99))])
        #expect(placed["huge"]?.span == WidgetSpan(columns: 6, rows: 2))
        #expect(placed["huge"]?.slot == GridSlot(column: 0, row: 0))
    }

    @Test("An out-of-bounds position falls back to packing instead of vanishing")
    func invalidPositionFallsBackToPacking() {
        let placed = board.arrange([request("stray", .small, at: GridSlot(column: 99, row: 99))])
        #expect(placed["stray"]?.slot == GridSlot(column: 0, row: 0))
    }

    @Test("Two widgets pinned to the same cell cannot both take it")
    func collidingPinsDoNotOverlap() {
        let slot = GridSlot(column: 2, row: 0)
        let placed = board.arrange([
            request("first", .small, at: slot),
            request("second", .small, at: slot),
        ])

        #expect(placed["first"]?.slot == slot)
        // The loser is not lost — it packs somewhere else entirely.
        #expect(placed["second"]?.slot != slot)
        #expect(placed["second"] != nil)
    }

    @Test("No two placements ever overlap, whatever the mix")
    func placementsNeverOverlap() {
        let placed = board.arrange([
            request("a", .large, at: GridSlot(column: 0, row: 0)),
            request("b", .wide),
            request("c", .tall),
            request("d", .small),
            request("e", .small, at: GridSlot(column: 5, row: 1)),
            request("f", .wide),
        ])

        let all = Array(placed.values)
        for (index, placement) in all.enumerated() {
            for other in all[(index + 1)...] {
                #expect(!placement.overlaps(other), "\(placement) overlaps \(other)")
            }
        }
    }

    @Test("A zero-sized board places nothing and does not trap")
    func emptyBoardIsSafe() {
        let empty = NotchGrid(columns: 0, rows: 0, cellSize: 72, spacing: 12)
        #expect(empty.arrange([request("a", .small)]).isEmpty)
    }

    @Test("The older span-only packer agrees with arrange on unpositioned widgets")
    func spanPackerAgreesWithArrange() {
        let spans: [WidgetSpan] = [.large, .wide, .small]
        let rects = board.placements(for: spans)
        let placed = board.arrange([
            request("a", .large),
            request("b", .wide),
            request("c", .small),
        ])

        #expect(rects[0] == placed["a"].map(board.rect(for:)))
        #expect(rects[1] == placed["b"].map(board.rect(for:)))
        #expect(rects[2] == placed["c"].map(board.rect(for:)))
    }
}

@Suite("Live drop preview")
struct ArrangePreviewTests {
    private let board = NotchGrid(columns: 4, rows: 2, cellSize: 72, spacing: 12)

    private func request(_ id: String, _ span: WidgetSpan, at slot: GridSlot? = nil) -> WidgetArrangementRequest {
        WidgetArrangementRequest(id: id, span: span, preferred: slot)
    }

    @Test("Moving a widget unpins whoever is sitting in the landing cell")
    func relocateEvictsTheOccupant() {
        let origin = [
            request("held", .small, at: GridSlot(column: 0, row: 0)),
            request("sitter", .small, at: GridSlot(column: 2, row: 0)),
            request("other", .small, at: GridSlot(column: 3, row: 0)),
        ]
        let relocated = NotchGrid.relocate(
            origin,
            moving: "held",
            to: WidgetPlacement(slot: GridSlot(column: 2, row: 0), span: .small)
        )
        let placed = board.arrange(relocated)

        #expect(placed["held"]?.slot == GridSlot(column: 2, row: 0))
        #expect(placed["sitter"]?.slot == GridSlot(column: 0, row: 0))
        #expect(placed["other"]?.slot == GridSlot(column: 3, row: 0))
    }

    @Test("A previewed drop matches the packing a real drop would produce")
    func previewMatchesCommit() {
        let origin = [
            request("held", .wide, at: GridSlot(column: 0, row: 0)),
            request("blocker", .small, at: GridSlot(column: 2, row: 0)),
            request("packed", .small),
        ]
        let target = WidgetPlacement(slot: GridSlot(column: 1, row: 0), span: .wide)
        let preview = board.arrange(NotchGrid.relocate(origin, moving: "held", to: target))

        #expect(preview["held"]?.slot == target.slot)
        #expect(preview["held"]?.span == target.span)
        #expect(preview["blocker"]?.slot != target.slot)
        #expect(preview.values.filter { $0.overlaps(target) }.count == 1)
    }

    @Test("Growing a tile unpins whoever its new span would cover")
    func relocateGrowsOntoANeighbour() {
        let origin = [
            request("held", .small, at: GridSlot(column: 0, row: 0)),
            request("sitter", .small, at: GridSlot(column: 1, row: 0)),
        ]
        let grown = WidgetPlacement(slot: GridSlot(column: 0, row: 0), span: .wide)
        let placed = board.arrange(NotchGrid.relocate(origin, moving: "held", to: grown))

        #expect(placed["held"] == grown)
        #expect(placed["sitter"]?.slot != GridSlot(column: 1, row: 0))
        #expect(placed.values.filter { $0.overlaps(grown) }.count == 1)
    }

    @Test("Hiding a widget frees its cell for packing")
    func hidingFreesTheCell() {
        let origin = [
            request("gone", .small, at: GridSlot(column: 0, row: 0)),
            request("waiting", .small),
        ]
        let placed = board.arrange(origin.filter { $0.id != "gone" })

        #expect(placed["gone"] == nil)
        #expect(placed["waiting"]?.slot == GridSlot(column: 0, row: 0))
    }
}

@Suite("Placement overlap")
struct PlacementOverlapTests {
    private func placement(_ column: Int, _ row: Int, _ span: WidgetSpan) -> WidgetPlacement {
        WidgetPlacement(slot: GridSlot(column: column, row: row), span: span)
    }

    @Test("Touching edges do not count as overlapping")
    func adjacentIsNotOverlapping() {
        #expect(!placement(0, 0, .small).overlaps(placement(1, 0, .small)))
        #expect(!placement(0, 0, .small).overlaps(placement(0, 1, .small)))
    }

    @Test("Spans that share any cell overlap")
    func sharedCellsOverlap() {
        #expect(placement(0, 0, .wide).overlaps(placement(1, 0, .small)))
        #expect(placement(0, 0, .large).overlaps(placement(1, 1, .small)))
        #expect(placement(0, 0, .small).overlaps(placement(0, 0, .small)))
    }

    @Test("Overlap is symmetric")
    func symmetry() {
        let a = placement(0, 0, .large)
        let b = placement(1, 1, .wide)
        #expect(a.overlaps(b) == b.overlaps(a))
    }
}
