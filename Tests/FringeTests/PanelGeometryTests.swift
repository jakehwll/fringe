import CoreGraphics
import Testing

@testable import Fringe

/// A 1512×982 display with its origin away from zero, because a secondary
/// screen is exactly where an assumption of `origin == .zero` would hide.
private let geometry = PanelGeometry(
    screenFrame: CGRect(x: -1512, y: 300, width: 1512, height: 982),
    notchHeight: 32,
    contentTopPadding: 12,
    boardSize: CGSize(width: 492, height: 156)
)

@Suite("Panel placement on screen")
struct PanelPlacementTests {
    @Test("A panel is centred horizontally and flush with the top edge")
    func topCentred() {
        let rect = geometry.topCentred(CGSize(width: 400, height: 200))

        #expect(rect.midX == geometry.screenFrame.midX)
        #expect(rect.maxY == geometry.screenFrame.maxY)
        #expect(rect.width == 400)
        #expect(rect.height == 200)
    }

    @Test("Placement follows the screen rather than assuming an origin of zero")
    func respectsScreenOrigin() {
        let rect = geometry.topCentred(CGSize(width: 400, height: 200))
        let expectedX: CGFloat = -956 // screen midX (-756) less half the width
        let expectedY: CGFloat = 1082 // screen maxY (1282) less the height

        #expect(rect.minX == expectedX)
        #expect(rect.minY == expectedY)
    }

    @Test("A hot zone grows sideways and downwards, never above the screen top")
    func hotZoneGrowth() {
        let size = CGSize(width: 400, height: 200)
        let zone = geometry.hotZone(size, horizontal: 10, bottom: 20)
        let base = geometry.topCentred(size)

        #expect(zone.maxY == base.maxY)
        #expect(zone.maxY == geometry.screenFrame.maxY)
        #expect(zone.minX == base.minX - 10)
        #expect(zone.maxX == base.maxX + 10)
        #expect(zone.minY == base.minY - 20)
    }

    @Test("A hot zone stays centred and contains the region it covers")
    func hotZoneContainsBase() {
        let size = CGSize(width: 400, height: 200)
        let zone = geometry.hotZone(size, horizontal: 10, bottom: 20)

        #expect(zone.midX == geometry.screenFrame.midX)
        #expect(zone.contains(geometry.topCentred(size)))
    }

    @Test("A hot zone with no padding is exactly the region it covers")
    func unpaddedHotZone() {
        let size = CGSize(width: 400, height: 200)
        #expect(geometry.hotZone(size) == geometry.topCentred(size))
    }
}

@Suite("Screen and board coordinates")
struct BoardCoordinateTests {
    @Test("The board's origin sits below the notch, centred on the screen")
    func boardOrigin() {
        let origin = geometry.boardOrigin

        #expect(origin.x == geometry.screenFrame.midX - 246)
        // 32pt of notch plus 12pt of padding below the top edge.
        #expect(origin.y == geometry.screenFrame.maxY - 44)
    }

    @Test("The board's top-left corner converts to the board's zero")
    func originMapsToZero() {
        #expect(geometry.boardPoint(from: geometry.boardOrigin) == .zero)
    }

    /// The axis flip is the part that is easy to get silently wrong: screen y
    /// grows upwards, board y grows downwards.
    @Test("Moving down the screen moves down the board")
    func yAxisIsFlipped() {
        let top = geometry.boardPoint(from: geometry.boardOrigin)
        let lower = geometry.boardPoint(
            from: CGPoint(x: geometry.boardOrigin.x, y: geometry.boardOrigin.y - 50)
        )

        #expect(lower.y > top.y)
        #expect(lower.y == 50)
    }

    @Test("Moving right on screen moves right on the board")
    func xAxisIsNotFlipped() {
        let point = geometry.boardPoint(
            from: CGPoint(x: geometry.boardOrigin.x + 30, y: geometry.boardOrigin.y)
        )
        #expect(point.x == 30)
    }

    @Test("A point above the board reads as negative rather than clamping")
    func aboveTheBoardIsNegative() {
        let inNotch = geometry.boardPoint(
            from: CGPoint(x: geometry.boardOrigin.x, y: geometry.screenFrame.maxY)
        )
        #expect(inNotch.y == -44)
    }

    @Test("Converting to the board and back is lossless", arguments: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 120, y: 40),
        CGPoint(x: 491, y: 155),
        CGPoint(x: -30, y: -12),
        CGPoint(x: 1000, y: 900)
    ])
    func roundTrip(board: CGPoint) {
        let screen = geometry.screenPoint(from: board)
        #expect(geometry.boardPoint(from: screen) == board)
    }

    @Test("The bottom-right of the board maps to the board's far corner")
    func farCorner() {
        let corner = CGPoint(x: geometry.boardSize.width, y: geometry.boardSize.height)
        let screen = geometry.screenPoint(from: corner)

        #expect(screen.x == geometry.boardOrigin.x + 492)
        #expect(screen.y == geometry.boardOrigin.y - 156)
    }

    /// The `simulateNotch` incident in miniature: a wrong notch height shifts
    /// the whole board, so a drag lands in the wrong row while every cell
    /// still looks correct on screen.
    @Test("A taller notch pushes the board down by exactly that much")
    func notchHeightShiftsTheBoard() {
        var taller = geometry
        taller.notchHeight += 10

        let point = CGPoint(x: geometry.boardOrigin.x, y: geometry.boardOrigin.y)
        #expect(taller.boardPoint(from: point).y == -10)
        #expect(taller.boardOrigin.y == geometry.boardOrigin.y - 10)
    }

    @Test("A board rect becomes an AppKit rect whose top edge matches")
    func screenRectFlipsY() {
        let boardRect = CGRect(x: 10, y: 20, width: 72, height: 72)
        let screen = geometry.screenRect(from: boardRect)
        let topLeft = geometry.screenPoint(from: boardRect.origin)

        #expect(screen.minX == topLeft.x)
        #expect(screen.maxY == topLeft.y)
        #expect(screen.size == boardRect.size)
    }
}

@Suite("Drag off the panel")
struct OffPanelDropTests {
    private let panelSize = CGSize(width: 400, height: 200)

    @Test("A pointer still on the panel is a move, not a remove")
    func pointerOnPanelStays() {
        let panel = geometry.topCentred(panelSize)
        #expect(!geometry.isOffPanel(CGPoint(x: panel.midX, y: panel.midY), size: panelSize))
        #expect(!geometry.isOffPanel(CGPoint(x: panel.minX, y: panel.minY), size: panelSize))
        #expect(!geometry.isOffPanel(CGPoint(x: panel.maxX - 1, y: panel.maxY - 1), size: panelSize))
    }

    /// The Dock's rule: once the pointer has left the strip, letting go
    /// removes the icon. A sliver hanging off the silhouette is not enough.
    @Test("A pointer off the panel removes")
    func pointerOffPanelRemoves() {
        let panel = geometry.topCentred(panelSize)
        #expect(geometry.isOffPanel(CGPoint(x: panel.midX, y: panel.minY - 1), size: panelSize))
        #expect(geometry.isOffPanel(CGPoint(x: panel.minX - 1, y: panel.midY), size: panelSize))
        #expect(geometry.isOffPanel(CGPoint(x: panel.maxX + 1, y: panel.midY), size: panelSize))
    }

    @Test("The decision uses the silhouette, not a grown hot zone")
    func shadowMarginIsOffPanel() {
        let panel = geometry.topCentred(panelSize)
        let justOutside = CGPoint(x: panel.midX, y: panel.minY - 8)
        #expect(geometry.isOffPanel(justOutside, size: panelSize))
        #expect(geometry.hotZone(panelSize, bottom: 16).contains(justOutside))
    }
}

@Suite("Hit-testing the board")
@MainActor
struct BoardHitTestTests {
    private let grid = NotchGrid(columns: 6, rows: 2, cellSize: 72, spacing: 12)

    private var arrangement: BoardArrangement {
        BoardArrangement(
            grid: grid,
            placements: [
                "left": WidgetPlacement(slot: GridSlot(column: 0, row: 0), span: .small),
                "big": WidgetPlacement(slot: GridSlot(column: 2, row: 0), span: .large)
            ]
        )
    }

    @Test("A point inside a tile finds that tile")
    func findsWidget() {
        #expect(arrangement.widget(at: CGPoint(x: 10, y: 10)) == "left")
        #expect(arrangement.widget(at: CGPoint(x: 200, y: 100)) == "big")
    }

    @Test("A point in a gutter finds nothing")
    func gutterIsEmpty() {
        // The gap between column 0 and column 1.
        #expect(arrangement.widget(at: CGPoint(x: 78, y: 10)) == nil)
    }

    @Test("A point on an empty cell finds nothing")
    func emptyCellIsEmpty() {
        #expect(arrangement.widget(at: CGPoint(x: 100, y: 100)) == nil)
    }

    @Test("The resize corner is inside the tile it resizes")
    func gripIsWithinItsTile() {
        let rect = arrangement.rect(of: "left")!
        let corner = CGPoint(x: rect.maxX - 2, y: rect.maxY - 2)

        #expect(arrangement.grip(at: corner) == "left")
        #expect(arrangement.widget(at: corner) == "left")
    }

    @Test("The middle of a tile is not its resize corner")
    func centreIsNotAGrip() {
        let rect = arrangement.rect(of: "left")!
        #expect(arrangement.grip(at: CGPoint(x: rect.midX, y: rect.midY)) == nil)
    }

    @Test("The minus badge is the top-left of its tile")
    func removeBadgeIsTopLeft() {
        let rect = arrangement.rect(of: "left")!
        #expect(arrangement.removeBadge(at: CGPoint(x: rect.minX + 2, y: rect.minY + 2)) == "left")
        #expect(arrangement.removeBadge(at: CGPoint(x: rect.midX, y: rect.midY)) == nil)
        #expect(arrangement.grip(at: CGPoint(x: rect.minX + 2, y: rect.minY + 2)) == nil)
    }

    @Test("Occupied cells cover every cell a span claims")
    func occupancyCoversSpans() {
        let occupied = arrangement.occupiedCells()

        #expect(occupied.contains(0))          // left, at (0, 0)
        #expect(occupied.contains(2))          // big, top-left
        #expect(occupied.contains(3))          // big, top-right
        #expect(occupied.contains(6 + 2))      // big, bottom-left
        #expect(occupied.contains(6 + 3))      // big, bottom-right
        #expect(!occupied.contains(1))         // genuinely empty
        #expect(occupied.count == 5)
    }
}
