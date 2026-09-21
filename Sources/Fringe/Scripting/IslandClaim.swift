import CoreGraphics
import Foundation

/// What a widget's `island()` returned: two nodes for the collapsed wings,
/// plus a priority so the host can pick a winner without knowing what
/// "battery" or "now playing" means.
struct IslandClaim: Equatable {
    var priority: Int
    var left: WidgetNode
    var right: WidgetNode
    /// Named action for a click on the right wing while peeked. `"playPause"`
    /// is the only one the window controller special-cases today.
    var action: String?

    static func parse(_ value: Any?) -> IslandClaim? {
        guard let object = value as? [AnyHashable: Any],
              let left = WidgetNode.parse(object["left"]),
              let right = WidgetNode.parse(object["right"])
        else { return nil }

        let priority: Int
        if let number = object["priority"] as? NSNumber {
            priority = number.intValue
        } else {
            priority = 0
        }

        let action = object["action"] as? String
        return IslandClaim(
            priority: priority,
            left: left,
            right: right,
            action: (action?.isEmpty == false) ? action : nil
        )
    }

    /// Highest priority wins. On a tie, the later claim keeps the island —
    /// callers should pass widgets in board order so a later script can
    /// override an earlier one at the same rank.
    static func winning(_ claims: [IslandClaim]) -> IslandClaim? {
        claims.max(by: { $0.priority < $1.priority })
    }
}

/// The claim that currently owns the collapsed wings.
struct IslandOccupancy: Equatable {
    var widgetID: String
    var claim: IslandClaim
}

extension IslandOccupancy {
    static func resolve(
        from widgets: [(id: String, enabled: Bool, claim: IslandClaim?)]
    ) -> IslandOccupancy? {
        widgets
            .filter(\.enabled)
            .compactMap { widget in
                widget.claim.map { IslandOccupancy(widgetID: widget.id, claim: $0) }
            }
            .max(by: { $0.claim.priority < $1.claim.priority })
    }
}

/// Host facts `island()` cannot observe itself: MagSafe just flipped, the
/// pointer is on the island, and the wing metrics so a script can size
/// art, glyphs, and the equaliser to the same content square.
struct IslandScriptContext: Equatable {
    var pulse: Bool
    var hover: Bool
    var side: CGFloat
    var wing: CGFloat

    static let zero = IslandScriptContext(pulse: false, hover: false, side: 20, wing: 36)

    var scriptValue: [String: Any] {
        [
            "pulse": pulse,
            "hover": hover,
            "side": Double(side),
            "wing": Double(wing),
        ]
    }
}
