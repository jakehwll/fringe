import CoreGraphics
import Foundation
import Observation

/// Everything the panel is built from: the handful of preferences the settings
/// window exposes, which persist to `UserDefaults`, plus the fixed layout
/// constants that are only tuned in code.
///
/// This is a reference type so that edits in the settings window reach the panel
/// live — SwiftUI observes it, and the window controller re-measures when a value
/// that affects geometry changes.
@MainActor
@Observable
final class NotchSettings {
    // MARK: - Preferences

    var columns = Default.columns
    var rows = Default.rows

    /// Script filenames in the order the user arranged them. Anything missing
    /// from this list still shows — it just sorts after the arranged ones.
    var widgetOrder: [String] = []

    /// Spans last used on the board, keyed by script filename. Packing may
    /// shrink a declared size to fit; that fitted span is written here so
    /// the next arrange does not ask for the original and bounce.
    var widgetSpans: [String: [Int]] = [:]

    func span(for id: String, declared: WidgetSpan) -> WidgetSpan {
        guard let pair = widgetSpans[id], pair.count == 2 else { return declared }
        return WidgetSpan(columns: pair[0], rows: pair[1])
    }

    func setSpan(_ span: WidgetSpan, for id: String) {
        widgetSpans[id] = [span.columns, span.rows]
    }

    /// Writes the cells the board actually used — including sizes packing
    /// shrank to fit. Without this a fitted 1×2 is visual-only, the next
    /// arrange asks for 3×2 again, the preferred cell refuses it, and the
    /// tile springs back to wherever packing first put it.
    func commit(_ placements: [String: WidgetPlacement]) {
        var spans = widgetSpans
        var positions = widgetPositions
        for (id, placement) in placements {
            spans[id] = [placement.span.columns, placement.span.rows]
            positions[id] = [placement.slot.column, placement.slot.row]
        }
        widgetSpans = spans
        widgetPositions = positions
    }

    /// Scripts switched off. They stay on disk and in the settings list, they
    /// just do not render.
    var disabledWidgets: Set<String> = []

    func isEnabled(_ id: String) -> Bool {
        !disabledWidgets.contains(id)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        if enabled {
            disabledWidgets.remove(id)
        } else {
            disabledWidgets.insert(id)
        }
    }

    /// Cells widgets last occupied. Widgets without an entry pack into
    /// whatever space is left.
    var widgetPositions: [String: [Int]] = [:]

    func position(for id: String) -> GridSlot? {
        guard let pair = widgetPositions[id], pair.count == 2 else { return nil }
        return GridSlot(column: pair[0], row: pair[1])
    }

    func setPosition(_ slot: GridSlot, for id: String) {
        widgetPositions[id] = [slot.column, slot.row]
    }

    func clearPosition(for id: String) {
        widgetPositions.removeValue(forKey: id)
    }

    /// Values the user set for a widget's declared settings, keyed by script
    /// filename then field id. Missing keys mean "use the script's default".
    var widgetValues: [String: [String: Any]] = [:]

    func widgetValue(_ widgetID: String, key: String) -> Any? {
        widgetValues[widgetID]?[key]
    }

    func setWidgetValue(_ value: Any, widgetID: String, key: String) {
        var fields = widgetValues[widgetID] ?? [:]
        fields[key] = value
        widgetValues[widgetID] = fields
    }

    /// Capabilities the user has allowed, keyed by script filename. Missing
    /// means nothing is granted — declaration is not authorisation. Bundled
    /// examples are seeded on first launch so weather and now-playing work.
    var widgetCapabilityGrants: [String: [String]] = ExampleScripts.bundledGrants

    func grantedCapabilities(for id: String) -> WidgetPermissions {
        WidgetPermissions.fromKeys(widgetCapabilityGrants[id])
    }

    func setGranted(_ granted: WidgetPermissions, for id: String) {
        var grants = widgetCapabilityGrants
        grants[id] = granted.keys
        widgetCapabilityGrants = grants
    }

    // MARK: - Grid

    var cellSize: CGFloat = 72
    var cellSpacing: CGFloat = 12

    var grid: NotchGrid {
        NotchGrid(columns: columns, rows: rows, cellSize: cellSize, spacing: cellSpacing)
    }

    static let columnRange = 3...10
    static let rowRange = 1...4

    // MARK: - Fixed layout

    /// Size used to draw a fake notch on displays that do not have a physical one.
    var simulatedNotchSize = CGSize(width: 196, height: 32)

    /// How far the outward-curving top corners flare into the surrounding screen edge.
    var flareRadius: CGFloat = 9
    var collapsedBottomRadius: CGFloat = 11
    var expandedBottomRadius: CGFloat = 26

    /// How long the pointer has to leave the expanded panel before it closes.
    var collapseDelay: TimeInterval = 0.18

    /// Extra drop and widening while the pointer is over the collapsed island.
    /// Enough to notice, not enough to read as opening.
    var hoverPeekWidth: CGFloat = 20
    var hoverPeekHeight: CGFloat = 8
    var hoverPeekBottomRadius: CGFloat = 14

    /// Inset of the grid within the panel, below the header band.
    var contentHorizontalPadding: CGFloat = 20
    var contentBottomPadding: CGFloat = 20
    var contentTopPadding: CGFloat = 12

    /// Inset of the header items from the outer edges of the panel, and the
    /// narrowest each side of the header is allowed to get. Sized for the
    /// pencil, gear, and the overflow warning — the left of the cutout is
    /// empty on purpose.
    var headerHorizontalPadding: CGFloat = 18
    var headerSideMinimum: CGFloat = 108

    // MARK: - Media island

    /// How far the media island hangs below the hardware cutout.
    ///
    /// Zero on purpose. The island grows sideways out of the notch and keeps
    /// the cutout's exact height — dropping below it puts a black lip across
    /// the menu bar that nothing else on the system does.
    var islandDrop: CGFloat = 0

    /// Inset above and below the island's contents, which is what sets the
    /// artwork size: on a 32pt cutout this leaves 20pt of artwork.
    var islandContentInset: CGFloat = 6

    /// Padding either side of each wing's content. Since a wing is built as
    /// `content + padding * 2`, this is every horizontal gap around both the
    /// artwork and the equaliser. Battery percent needs this width — a 20pt
    /// content square cannot hold "100%" at a readable size.
    var islandPadding: CGFloat = 8

    /// Extra slack around the hot zones so the panel is easy to hit and does not
    /// flicker shut when the pointer skims the edge.
    var collapsedHoverPadding: CGFloat = 4
    var expandedHoverPadding: CGFloat = 16

    /// Transparent margin kept around the panel content so the drop shadow and the
    /// corner flares are never clipped by the window.
    var windowHorizontalPadding: CGFloat = 48
    var windowBottomPadding: CGFloat = 64

    /// The expanded panel is exactly as big as the grid it holds, plus the header
    /// band and the surrounding insets. The only floor is the header itself: the
    /// gear still needs room on the trailing side of the cutout, and the leading
    /// side matches it so the silhouette stays centred.
    func expandedSize(notch: CGSize) -> CGSize {
        expandedSize(notch: notch, grid: grid)
    }

    func expandedSize(notch: CGSize, grid: NotchGrid) -> CGSize {
        let content = grid.contentSize
        return CGSize(
            width: max(
                content.width + contentHorizontalPadding * 2,
                notch.width + headerSideMinimum * 2
            ),
            height: notch.height + contentTopPadding + content.height + contentBottomPadding
        )
    }

    /// Largest the silhouette can grow. The panel window is this size (plus
    /// shadow padding) for its whole life, so resizing the grid only animates
    /// the path — never the window origin, which is what used to lift the
    /// header off the top of the screen mid-spring.
    func windowCanvasSize(notch: CGSize) -> CGSize {
        expandedSize(
            notch: notch,
            grid: NotchGrid(
                columns: Self.columnRange.upperBound,
                rows: Self.rowRange.upperBound,
                cellSize: cellSize,
                spacing: cellSpacing
            )
        )
    }

    func windowOuterSize(notch: CGSize) -> CGSize {
        let canvas = windowCanvasSize(notch: notch)
        return CGSize(
            width: canvas.width + windowHorizontalPadding * 2,
            height: canvas.height + windowBottomPadding
        )
    }

    /// Collapsed island size. Idle, this is the hardware cutout; with an
    /// occupant (media, battery) it grows into Dynamic Island-style wings.
    func collapsedSize(notch: CGSize, hasWings: Bool) -> CGSize {
        hasWings ? islandLayout(notch: notch).size : notch
    }

    /// Bottom corner radius of the resting silhouette. The island is taller than
    /// the cutout, so it needs a correspondingly larger radius or it reads as a
    /// box rather than a pill.
    func restingBottomRadius(notch: CGSize, hasWings: Bool) -> CGFloat {
        hasWings ? islandLayout(notch: notch).bottomRadius : collapsedBottomRadius
    }

    /// Every island dimension, derived together from `islandDrop`,
    /// `islandContentInset` and `islandPadding`.
    ///
    /// Each wing is a content square with `islandPadding` on both sides, which
    /// makes the wings equal by construction. That matters twice over: the
    /// silhouette stays symmetric about the cutout, so the drawn notch lines up
    /// with the hardware one, and each element is evenly spaced between the
    /// island's edge and the cutout.
    func islandLayout(notch: CGSize) -> IslandLayout {
        let height = notch.height + islandDrop
        let contentSide = max(12, height - islandContentInset * 2)

        return IslandLayout(
            size: CGSize(
                width: notch.width + (contentSide + islandPadding * 2) * 2,
                height: height
            ),
            notchWidth: notch.width,
            wingWidth: contentSide + islandPadding * 2,
            contentSide: contentSide,
            bottomRadius: min(height * 0.36, 14)
        )
    }

    struct IslandLayout: Equatable {
        var size: CGSize
        var notchWidth: CGFloat
        /// Content square plus its padding on either side.
        var wingWidth: CGFloat
        /// Side of the square each wing gives its content.
        var contentSide: CGFloat
        var bottomRadius: CGFloat
    }

    /// Collapsed island plus the hover peek. Used for both the silhouette and
    /// the hot zone, so the grown region stays easy to hit.
    func peekSize(notch: CGSize, hasWings: Bool) -> CGSize {
        let rest = collapsedSize(notch: notch, hasWings: hasWings)
        return CGSize(width: rest.width + hoverPeekWidth, height: rest.height + hoverPeekHeight)
    }

    @ObservationIgnored let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        persistOnChange()
    }

    func resetToDefaults() {
        columns = Default.columns
        rows = Default.rows
        widgetOrder = []
        widgetSpans = [:]
        widgetPositions = [:]
        disabledWidgets = []
        widgetValues = [:]
        widgetCapabilityGrants = ExampleScripts.bundledGrants
    }
}

extension ClosedRange where Bound == Int {
    func clamping(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

/// One key from a preferences domain. `isForeign` is the whole reason this
/// type exists: a key the current build does not write is how a retired
/// preference keeps changing behaviour with nothing on screen to show it.
struct StoredPreference: Equatable {
    var key: String
    var value: String
    var isForeign: Bool
}
