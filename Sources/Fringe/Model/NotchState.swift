import CoreGraphics
import Observation

@MainActor
@Observable
final class NotchState {
    enum Mode: Equatable {
        case collapsed
        case expanded
    }

    var mode: Mode = .collapsed
    var metrics = NotchMetrics(size: CGSize(width: 196, height: 32), isPhysical: false)

    /// Pointer is over the collapsed island. Drives the peek animation; click is
    /// what actually opens the panel.
    var isHovered = false

    /// Held open regardless of the pointer — used while the settings window is up,
    /// so edits can be previewed live.
    var isPinned = false

    /// Arranging mode: widgets can be dragged and resized, and the panel stays
    /// open while the pointer wanders off it mid-drag.
    var isEditing = false

    /// Live move or resize. Driven by the window controller's pointer
    /// tracking rather than SwiftUI gestures — a non-activating panel
    /// delivers gestures too unreliably to build an interaction on.
    var arrange: ArrangeSession?

    /// Widget under the pointer while arranging, and whether the pointer is
    /// specifically over its resize corner.
    var hoveredWidget: String?
    var hoveredGrip: String?
    var hoveredRemove: String?

    /// Bottom-right of the expanded silhouette — resizes the grid, not a tile.
    var hoveredPanelGrip = false
    var panelResize: PanelResizeSession?

    struct ArrangeSession: Equatable {
        enum Kind: Equatable {
            case move
            case resize
        }

        var widgetID: String
        var kind: Kind
        /// Board coordinates where the press landed.
        var startPoint: CGPoint
        /// The tile's rect when the drag began.
        var originRect: CGRect
        /// Cell the tile occupied at press, so a resize grows in place
        /// instead of packing to a new hole every frame.
        var originSlot: GridSlot
        var baseSpan: WidgetSpan
        var translation: CGSize = .zero
        /// Pointer has left the panel; dropping will hide the widget rather
        /// than snap it back onto the board.
        var isRemoving = false
        /// Dropped, and now springing into its cell. The session outlives the
        /// mouse-up so the tile can animate, and pointer updates have to leave
        /// it alone until it lands.
        var isSettling = false
        /// Cell the pointer is currently offering. Neighbours pack around this
        /// while the dragged tile follows the cursor, so the drop is not a
        /// surprise.
        var landing: WidgetPlacement?
    }

    /// Dragging the panel's own corner. Kept off `ArrangeSession` so a
    /// widget drag and a panel resize cannot be confused for each other.
    struct PanelResizeSession: Equatable {
        /// Screen coordinates where the press landed.
        var startPoint: CGPoint
        var columns: Int
        var rows: Int
    }

    var isExpanded: Bool { mode == .expanded }
}
