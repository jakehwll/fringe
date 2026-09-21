import CoreGraphics
import Foundation

/// What the geometry actually resolved to, as a value.
///
/// The debug pane draws this; tests assert against it. Keeping the readout
/// as data rather than as view-local arithmetic is the point: a number that
/// only exists on screen is the same class of invisibility as a persisted
/// preference nobody can inspect.
struct GeometryReport: Equatable {
    var screenName: String
    var screenFrame: CGRect
    var backingScale: CGFloat
    var isPhysical: Bool
    var notch: CGSize

    var columns: Int
    var rows: Int
    var cellSize: CGFloat
    var spacing: CGFloat
    var boardSize: CGSize
    var boardOrigin: CGPoint

    var collapsed: CGSize
    var expanded: CGSize
    var window: CGRect

    var widgets: [Widget]
    var stored: [StoredPreference]

    struct Widget: Equatable {
        var id: String
        /// `nil` when the widget did not fit.
        var slot: GridSlot?
        var span: WidgetSpan?
        /// Whether the user put it there, packing put it there, or it has
        /// nowhere to go. Invisible on the board itself, and it changes what
        /// dragging the widget next will do.
        var origin: Origin

        enum Origin: String, Equatable {
            case pinned
            case packed
            case unplaced
        }

        var detail: String {
            guard let slot, let span else { return "No room on the grid" }
            return "col \(slot.column), row \(slot.row)  ·  \(span.columns)×\(span.rows)  ·  \(origin.rawValue)"
        }
    }

    @MainActor
    init(
        screenName: String,
        screenFrame: CGRect,
        backingScale: CGFloat,
        metrics: NotchMetrics,
        settings: NotchSettings,
        placements: [String: WidgetPlacement],
        unplaced: [String],
        stored: [StoredPreference]
    ) {
        self.screenName = screenName
        self.screenFrame = screenFrame
        self.backingScale = backingScale
        isPhysical = metrics.isPhysical
        notch = metrics.size

        columns = settings.columns
        rows = settings.rows
        cellSize = settings.cellSize
        spacing = settings.cellSpacing
        boardSize = settings.grid.contentSize

        let geometry = PanelGeometry(
            screenFrame: screenFrame,
            notchHeight: metrics.size.height,
            contentTopPadding: settings.contentTopPadding,
            boardSize: boardSize
        )
        boardOrigin = geometry.boardOrigin
        collapsed = settings.collapsedSize(notch: metrics.size, hasWings: false)
        expanded = settings.expandedSize(notch: metrics.size)
        window = geometry.topCentred(settings.windowOuterSize(notch: metrics.size))

        let placed = placements.keys.sorted().map { id in
            let placement = placements[id]!
            return Widget(
                id: id,
                slot: placement.slot,
                span: placement.span,
                origin: settings.position(for: id) == nil ? .packed : .pinned
            )
        }
        let missing = unplaced.sorted().map { id in
            Widget(id: id, slot: nil, span: nil, origin: .unplaced)
        }
        widgets = placed + missing
        self.stored = stored
    }

    var screenDescription: String {
        screenName.isEmpty ? "No display" : screenName + (isPhysical ? " (notched)" : "")
    }

    var notchSource: String {
        isPhysical ? "Measured from hardware" : "Drawn stand-in"
    }

    /// Same numbers the pane shows, as copyable text.
    var plainText: String {
        var lines = ["Fringe diagnostics", ""]
        lines.append("Screen:    \(screenDescription) \(Self.format(screenFrame))")
        lines.append("Notch:     \(Self.format(notch)) \(isPhysical ? "measured" : "stand-in")")
        lines.append("Grid:      \(columns)×\(rows), board \(Self.format(boardSize))")
        lines.append("Origin:    \(Self.format(boardOrigin))")
        lines.append("Expanded:  \(Self.format(expanded))")
        lines.append("Window:    \(Self.format(window))")
        lines.append("")
        lines.append("Placement")
        if widgets.isEmpty {
            lines.append("  (none)")
        }
        for widget in widgets {
            lines.append("  \(widget.id): \(widget.detail)")
        }
        lines.append("")
        lines.append("Stored preferences")
        if stored.isEmpty {
            lines.append("  (none)")
        }
        for entry in stored {
            lines.append("  \(entry.key)\(entry.isForeign ? " [unknown]" : ""): \(entry.value)")
        }
        return lines.joined(separator: "\n")
    }

    static func format(_ size: CGSize) -> String {
        "\(number(size.width)) × \(number(size.height)) pt"
    }

    static func format(_ point: CGPoint) -> String {
        "(\(number(point.x)), \(number(point.y)))"
    }

    static func format(_ rect: CGRect) -> String {
        "(\(number(rect.minX)), \(number(rect.minY)))  \(number(rect.width)) × \(number(rect.height))"
    }

    static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}
