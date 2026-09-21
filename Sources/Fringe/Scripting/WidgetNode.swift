import CoreGraphics
import Foundation

/// What a widget script returns: a small tree of drawing primitives.
///
/// Deliberately not SwiftUI — scripts hand back plain JSON-ish objects and the
/// view layer decides how to draw them. Styling is kept as raw strings and
/// numbers here so nothing in the model has to know about fonts or colours.
indirect enum WidgetNode: Equatable {
    case text(TextNode)
    case symbol(SymbolNode)
    case stack(StackNode)
    case progress(ProgressNode)
    case artwork(ArtworkNode)
    case button(ButtonNode)
    /// A fixed gap when given a length, otherwise flexible. Fixed spacers are
    /// how you get an even *optical* rhythm: a stack's uniform spacing lands
    /// differently between two text nodes than between text and a shape,
    /// because a text frame carries the font's ascender and descender with it.
    case spacer(CGFloat?)
    case list(ListNode)
    case chart(ChartNode)
    /// Now-playing bars. Size is the box they fill; omitted, they take
    /// whatever the parent proposes.
    case equaliser(EqualiserNode)
}

struct EqualiserNode: Equatable {
    var playing = false
    var size: CGFloat?
}

/// The current now-playing artwork. Scripts cannot carry image bytes across the
/// bridge, so they ask for it by reference and the renderer supplies it.
struct ArtworkNode: Equatable {
    var blurred = false
    var cornerRadius: CGFloat = 8
    var opacity: Double = 1
    /// Largest square side. Without one the artwork is square and fits the
    /// height it is given. A cap rather than a pinned frame, so a small tile
    /// can shrink the cover instead of bursting out of the cell.
    var size: CGFloat?
    /// Fills the container on both axes instead, for use as a backdrop.
    var fill = false
    /// Darkens the artwork by this much. Prefer it to lowering `opacity` for
    /// backdrops: fading art towards black drains its colour to grey, while
    /// dimming keeps the hue and just lowers the level.
    var dim: Double = 0
}

/// Wraps a child in a tap target. Scripts stay pure — `render` returns a tree,
/// and interaction is a named action the host knows how to perform.
struct ButtonNode: Equatable {
    var action: String
    /// Inset around the child. This is the hit target — a bare glyph is a
    /// miserably small thing to aim at.
    var padding: CGFloat = 6
    var child: WidgetNode
}

struct TextNode: Equatable {
    var value: String
    var size: CGFloat = 13
    var weight: String = "regular"
    var opacity: Double = 1
    var color: String?
    var monospaced = false
    var lines: Int = 2
    /// `leading`, `center` or `trailing`. Setting it also stretches the text to
    /// the full width available, which is what makes left alignment stick
    /// inside a column that is wider than the string.
    var align: String?
    /// Clip with an ellipsis instead of shrinking the type to fit.
    var truncate = false
}

struct SymbolNode: Equatable {
    var name: String
    /// Font size, or the occupancy square when `fit` is on.
    var size: CGFloat = 14
    var opacity: Double = 1
    var color: String?
    /// Second palette layer (cloud vs sun, bolt vs rain). Ignored in mono.
    var secondary: String?
    /// Third palette layer, for glyphs like `cloud.bolt.rain.fill`.
    var tertiary: String?
    /// `mono`, `hierarchical`, `palette`, or `multicolor`. Nil is mono.
    var rendering: String?
    /// Scale the vector into `size`×`size`. Font-sized battery glyphs paint
    /// far outside that square because they are extra-wide.
    var fit = false
}

struct StackNode: Equatable {
    enum Axis: String {
        case vertical
        case horizontal
        /// Children stacked front to back, for backdrops.
        case layered
    }

    var axis: Axis = .vertical
    var spacing: CGFloat = 4
    var alignment: String = "center"
    var padding: CGFloat = 0
    var children: [WidgetNode] = []
}

struct ProgressNode: Equatable {
    var value: Double
    var color: String?
    var height: CGFloat = 4
}

/// A stack of rows. Each row is data, not a nested tree, so a script can hand
/// back a forecast or a file listing without building twenty `hstack`s by hand.
struct ListNode: Equatable {
    var items: [Item] = []

    struct Item: Equatable {
        var title: String
        var subtitle: String?
        var symbol: String?
        var value: String?
        var color: String?
        var secondary: String?
        var tertiary: String?
        var rendering: String?
    }
}

/// A sparkline or a row of bars. Values are normalised to the series' own
/// min/max — a temperature chart should not have to know the tile's height.
struct ChartNode: Equatable {
    enum Kind: String {
        case line
        case bars
    }

    var values: [Double] = []
    var kind: Kind = .line
    var color: String?
    var height: CGFloat = 28
    var fill = false
}

// MARK: - Parsing

extension WidgetNode {
    static let maxDepth = 8
    static let maxChildren = 32
    static let maxListItems = 24
    static let maxChartValues = 64
    static let maxTextCharacters = 512

    /// Builds a node from the dictionary a script returned. Anything unrecognised
    /// is dropped rather than failing the whole tree, so one typo in a nested
    /// child does not blank the widget. Depth and fan-out are capped so a
    /// 100ms script cannot hand Swift a tree that hangs the main thread.
    static func parse(_ value: Any?, depth: Int = 0) -> WidgetNode? {
        guard depth <= maxDepth,
              let object = value as? [AnyHashable: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "text":
            guard var text = object["value"] as? String else { return nil }
            if text.count > maxTextCharacters {
                text = String(text.prefix(maxTextCharacters))
            }
            return .text(
                TextNode(
                    value: text,
                    size: clamped(number(object["size"]), 8...96, default: 13),
                    weight: object["weight"] as? String ?? "regular",
                    opacity: Double(clamped(number(object["opacity"]), 0...1, default: 1)),
                    color: object["color"] as? String,
                    monospaced: object["monospaced"] as? Bool ?? false,
                    lines: min(max((object["lines"] as? NSNumber)?.intValue ?? 2, 1), 8),
                    align: object["align"] as? String,
                    truncate: object["truncate"] as? Bool ?? false
                )
            )

        case "symbol":
            guard let name = object["name"] as? String else { return nil }
            return .symbol(
                SymbolNode(
                    name: name,
                    size: clamped(number(object["size"]), 8...96, default: 14),
                    opacity: Double(clamped(number(object["opacity"]), 0...1, default: 1)),
                    color: object["color"] as? String,
                    secondary: object["secondary"] as? String,
                    tertiary: object["tertiary"] as? String,
                    rendering: object["rendering"] as? String,
                    fit: object["fit"] as? Bool ?? false
                )
            )

        case "stack":
            let children = (object["children"] as? [Any] ?? [])
                .prefix(maxChildren)
                .compactMap { WidgetNode.parse($0, depth: depth + 1) }
            return .stack(
                StackNode(
                    axis: StackNode.Axis(rawValue: object["axis"] as? String ?? "") ?? .vertical,
                    spacing: clamped(number(object["spacing"]), 0...24, default: 4),
                    alignment: object["alignment"] as? String ?? "center",
                    padding: clamped(number(object["padding"]), 0...24, default: 0),
                    children: Array(children)
                )
            )

        case "progress":
            return .progress(
                ProgressNode(
                    value: Double(number(object["value"]) ?? 0).clamped(to: 0...1),
                    color: object["color"] as? String,
                    height: clamped(number(object["height"]), 1...16, default: 4)
                )
            )

        case "artwork":
            return .artwork(
                ArtworkNode(
                    blurred: object["blurred"] as? Bool ?? false,
                    cornerRadius: clamped(number(object["corner"]), 0...40, default: 8),
                    opacity: Double(clamped(number(object["opacity"]), 0...1, default: 1)),
                    size: number(object["size"]).map { clamped($0, 8...160, default: $0) },
                    fill: object["fill"] as? Bool ?? false,
                    dim: Double(number(object["dim"]) ?? 0).clamped(to: 0...1)
                )
            )

        case "button":
            guard let action = object["action"] as? String,
                  let child = WidgetNode.parse(object["child"], depth: depth + 1)
            else { return nil }
            return .button(
                ButtonNode(
                    action: action,
                    padding: clamped(number(object["padding"]), 0...24, default: 6),
                    child: child
                )
            )

        case "spacer":
            return .spacer(number(object["length"]).map { clamped($0, 0...80, default: $0) })

        case "list":
            let items = (object["items"] as? [Any] ?? []).prefix(maxListItems).compactMap { raw -> ListNode.Item? in
                guard let row = raw as? [AnyHashable: Any],
                      let title = row["title"] as? String
                else { return nil }
                return ListNode.Item(
                    title: String(title.prefix(maxTextCharacters)),
                    subtitle: (row["subtitle"] as? String).map { String($0.prefix(maxTextCharacters)) },
                    symbol: row["symbol"] as? String,
                    value: (row["value"] as? String).map { String($0.prefix(maxTextCharacters)) },
                    color: row["color"] as? String,
                    secondary: row["secondary"] as? String,
                    tertiary: row["tertiary"] as? String,
                    rendering: row["rendering"] as? String
                )
            }
            return .list(ListNode(items: Array(items)))

        case "chart":
            let values = (object["values"] as? [Any] ?? [])
                .prefix(maxChartValues)
                .compactMap { number($0).map(Double.init) }
            return .chart(
                ChartNode(
                    values: Array(values),
                    kind: ChartNode.Kind(rawValue: object["kind"] as? String ?? "") ?? .line,
                    color: object["color"] as? String,
                    height: clamped(number(object["height"]), 8...80, default: 28),
                    fill: object["fill"] as? Bool ?? false
                )
            )

        case "equaliser":
            return .equaliser(
                EqualiserNode(
                    playing: object["playing"] as? Bool ?? false,
                    size: number(object["size"]).map { clamped($0, 8...80, default: $0) }
                )
            )

        default:
            return nil
        }
    }

    /// JavaScript numbers arrive as `NSNumber`, but a script may equally hand back
    /// a numeric string.
    private static func number(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
        if let string = value as? String, let parsed = Double(string) { return CGFloat(parsed) }
        return nil
    }

    private static func clamped(_ value: CGFloat?, _ range: ClosedRange<CGFloat>, default fallback: CGFloat) -> CGFloat {
        guard let value, value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
