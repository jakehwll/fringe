import SwiftUI

/// Widens text to the space available so its alignment is visible. Without a
/// frame a `Text` is exactly as wide as its string, and aligning it does
/// nothing.
///
/// `minWidth: 0` is load-bearing either way. Text's own minimum is the
/// untruncated string, and that is what lets a long title shove a tile past
/// its cell. Truncation only happens once the label can actually shrink.
struct TextStretch: ViewModifier {
    var align: String?

    func body(content: Content) -> some View {
        if let align {
            content.frame(minWidth: 0, maxWidth: .infinity, alignment: .frameAlignment(align))
        } else {
            content.frame(minWidth: 0)
        }
    }
}

struct ArtworkSizing: ViewModifier {
    var size: CGFloat?
    var fills: Bool

    func body(content: Content) -> some View {
        if let size {
            // A cap, not a floor. `size` exists so a cover cannot eat a wide
            // tile; pinning the frame to exactly that made a 1-wide player
            // refuse to sit in a cell smaller than the art.
            content
                .frame(
                    minWidth: 0,
                    idealWidth: size,
                    maxWidth: size,
                    minHeight: 0,
                    idealHeight: size,
                    maxHeight: size
                )
                .aspectRatio(1, contentMode: .fit)
        } else if fills {
            content.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        } else {
            content.aspectRatio(1, contentMode: .fit)
        }
    }
}

// MARK: - Script value mapping

extension Font.Weight {
    static func named(_ name: String) -> Font.Weight {
        switch name.lowercased() {
        case "ultralight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: .regular
        }
    }
}

extension TextAlignment {
    static func textAlignment(_ name: String?) -> TextAlignment {
        switch name?.lowercased() {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }
}

extension Alignment {
    static func frameAlignment(_ name: String) -> Alignment {
        switch name.lowercased() {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }
}

extension HorizontalAlignment {
    static func horizontalAlignment(_ name: String) -> HorizontalAlignment {
        switch name.lowercased() {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }
}

extension VerticalAlignment {
    static func verticalAlignment(_ name: String) -> VerticalAlignment {
        switch name.lowercased() {
        case "top": .top
        case "bottom": .bottom
        default: .center
        }
    }
}

/// Polyline through `values`, optionally closed down to the baseline so it
/// can be filled. All-equal series collapse to a midline rather than a
/// divide-by-zero.
struct Sparkline: Shape {
    var values: [Double]
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        let points = ChartScaling.points(values: values, in: rect)
        guard let first = points.first else { return Path() }

        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        if closed, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

struct BarChart: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        guard !values.isEmpty else { return Path() }
        let range = ChartScaling.range(values)
        let gap: CGFloat = 2
        let width = max(1, (rect.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count))

        var path = Path()
        for (index, value) in values.enumerated() {
            let height = range.span == 0
                ? rect.height * 0.4
                : rect.height * CGFloat((value - range.min) / range.span)
            let originX = rect.minX + CGFloat(index) * (width + gap)
            path.addRoundedRect(
                in: CGRect(x: originX, y: rect.maxY - max(1, height), width: width, height: max(1, height)),
                cornerSize: CGSize(width: 1.5, height: 1.5)
            )
        }
        return path
    }
}

private enum ChartScaling {
    static func range(_ values: [Double]) -> (min: Double, span: Double) {
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        return (minValue, maxValue - minValue)
    }

    static func points(values: [Double], in rect: CGRect) -> [CGPoint] {
        guard values.count > 1 else {
            return [CGPoint(x: rect.midX, y: rect.midY)]
        }
        let range = range(values)
        let step = rect.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let originY = range.span == 0
                ? rect.midY
                : rect.maxY - CGFloat((value - range.min) / range.span) * rect.height
            return CGPoint(x: rect.minX + CGFloat(index) * step, y: originY)
        }
    }
}

extension Color {
    /// Accepts `#rgb`, `#rrggbb`, `#rrggbbaa` or a handful of names.
    init(scriptValue: String) {
        let named: [String: Color] = [
            "white": .white, "black": .black, "red": .red, "orange": .orange,
            "yellow": .yellow, "green": .green, "mint": .mint, "teal": .teal,
            "blue": .blue, "indigo": .indigo, "purple": .purple, "pink": .pink,
            "gray": .gray, "grey": .gray
        ]
        if let match = named[scriptValue.lowercased()] {
            self = match
            return
        }

        var hex = scriptValue.trimmingCharacters(in: .whitespaces)
        hex.removeFirst(hex.hasPrefix("#") ? 1 : 0)
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
            self = .white
            return
        }

        let hasAlpha = hex.count == 8
        let shift = hasAlpha ? 8 : 0
        self = Color(
            .sRGB,
            red: Double((value >> (16 + shift)) & 0xFF) / 255,
            green: Double((value >> (8 + shift)) & 0xFF) / 255,
            blue: Double((value >> shift) & 0xFF) / 255,
            opacity: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }
}
