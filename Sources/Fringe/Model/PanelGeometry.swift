import CoreGraphics

/// Where the panel sits on a particular screen.
///
/// Everything the panel puts on screen is centred on the display's horizontal
/// midpoint and hung from its top edge. The window frame, every hot zone, and
/// the conversion that turns a pointer location into a grid cell all repeat
/// that one rule, so it lives here once — as a plain value with no AppKit in
/// it, which is what lets it be checked without a display attached.
///
/// Two coordinate spaces meet here, and mixing them up is the single easiest
/// mistake to make in this app:
///
/// - **Screen** is AppKit's: origin at the bottom-left of the display, y
///   increasing upwards.
/// - **Board** is the grid's: origin at the top-left of the first cell, y
///   increasing downwards, matching what SwiftUI hands the layout.
struct PanelGeometry: Equatable {
    var screenFrame: CGRect

    /// Height of the notch cutout. The board hangs below it.
    var notchHeight: CGFloat

    /// Gap between the bottom of the cutout and the first row of cells.
    var contentTopPadding: CGFloat

    /// Point size of the grid itself, excluding any padding around it.
    var boardSize: CGSize

    /// A rect of `size`, centred horizontally and flush with the top edge.
    func topCentred(_ size: CGSize) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// `topCentred`, grown outwards and downwards.
    ///
    /// Hot zones are deliberately larger than the thing they cover so the
    /// panel is easy to hit and does not flicker shut when the pointer skims
    /// an edge. Nothing grows upwards: there is no screen above the top edge
    /// to grow into.
    func hotZone(_ size: CGSize, horizontal: CGFloat = 0, bottom: CGFloat = 0) -> CGRect {
        let rect = topCentred(size)
        return CGRect(
            x: rect.minX - horizontal,
            y: rect.minY - bottom,
            width: rect.width + horizontal * 2,
            height: rect.height + bottom
        )
    }

    /// Top-left corner of the grid, in screen coordinates.
    var boardOrigin: CGPoint {
        CGPoint(
            x: screenFrame.midX - boardSize.width / 2,
            y: screenFrame.maxY - notchHeight - contentTopPadding
        )
    }

    /// Board coordinates for a point on screen.
    func boardPoint(from screen: CGPoint) -> CGPoint {
        CGPoint(x: screen.x - boardOrigin.x, y: boardOrigin.y - screen.y)
    }

    /// Inverse of `boardPoint`.
    ///
    /// Nothing in the app needs this, but a conversion only ever applied in
    /// one direction is one nobody can check. With both halves present, a
    /// round-trip pins down the axis flip that is otherwise easy to get
    /// subtly, silently wrong.
    func screenPoint(from board: CGPoint) -> CGPoint {
        CGPoint(x: board.x + boardOrigin.x, y: boardOrigin.y - board.y)
    }

    /// AppKit rect for a board-space tile. Board origin is the tile's top-left
    /// (y down); windows want the bottom-left (y up), which is the flip a drag
    /// preview has to get right or the tile jumps the instant it lifts.
    func screenRect(from board: CGRect) -> CGRect {
        let topLeft = screenPoint(from: board.origin)
        return CGRect(
            x: topLeft.x,
            y: topLeft.y - board.height,
            width: board.width,
            height: board.height
        )
    }

    /// Whether dropping a dragged widget at this screen point should hide it
    /// rather than snap it back onto the board — the Dock's "pull it off" rule.
    /// The test is the silhouette, not the window's shadow margin: a sliver
    /// hanging off an edge is still a move.
    func isOffPanel(_ point: CGPoint, size: CGSize) -> Bool {
        !topCentred(size).contains(point)
    }
}
