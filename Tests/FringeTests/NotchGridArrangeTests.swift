import CoreGraphics
import Testing

@testable import Fringe

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
            request("other", .small, at: GridSlot(column: 3, row: 0))
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
            request("packed", .small)
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
            request("sitter", .small, at: GridSlot(column: 1, row: 0))
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
            request("waiting", .small)
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
        let left = placement(0, 0, .large)
        let right = placement(1, 1, .wide)
        #expect(left.overlaps(right) == right.overlaps(left))
    }
}
