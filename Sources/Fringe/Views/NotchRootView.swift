import SwiftUI

/// Fills the whole panel window. Nothing here changes size or position: the
/// notch is a path drawn inside the full-window canvas, and only that path
/// animates. Animating a view frame instead would let SwiftUI interpolate the
/// origin too, and the body would visibly peel away from the top of the screen
/// as the spring overshot.
struct NotchRootView: View {
    let state: NotchState
    let settings: NotchSettings
    let library: ScriptLibrary
    let nowPlaying: NowPlayingController
    let onOpenSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(.black)
            compactIsland
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(shape)
        .shadow(color: .black.opacity(shadowOpacity), radius: 24, y: 14)
        .animation(transition, value: state.mode)
        .animation(hoverTransition, value: state.isHovered)
        .animation(.easeInOut(duration: 0.2), value: state.metrics)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: occupancy?.widgetID)
        // Springs the silhouette path. Content and the island opt out below
        // so a grid resize cannot interpolate their origin off the screen top.
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: settings.columns)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: settings.rows)
    }

    /// The content is laid out at its expanded size at all times and clipped by
    /// the silhouette. Sizing it with the body would reflow text on every frame.
    ///
    /// The frame itself must not spring: SwiftUI interpolates a changing height
    /// through the view's centre, which lifts the header off the top of the
    /// screen and then snaps it back when the window origin catches up. The
    /// silhouette still springs — that is `NotchShape.animatableData`.
    private var content: some View {
        NotchContentView(
            state: state,
            settings: settings,
            library: library,
            nowPlaying: nowPlaying,
            onOpenSettings: onOpenSettings
        )
            .frame(
                width: expandedSize.width,
                height: expandedSize.height,
                alignment: .top
            )
            .animation(nil, value: settings.columns)
            .animation(nil, value: settings.rows)
            .opacity(state.isExpanded ? 1 : 0)
            .allowsHitTesting(state.isExpanded)
    }

    /// Visible only while collapsed with an occupant, sitting in the two wings
    /// that grow out of the hardware notch.
    ///
    /// Framed to `bodySize`, not to the resting island size: the silhouette
    /// grows on hover, and anything sized to the resting size instead would be
    /// top-aligned inside it, dumping the entire peek below the artwork.
    private var compactIsland: some View {
        let layout = settings.islandLayout(notch: state.metrics.size)
        return Group {
            if let occupancy {
                CompactIslandView(
                    claim: occupancy.claim,
                    layout: layout,
                    context: islandContext
                )
            }
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .animation(nil, value: settings.columns)
        .animation(nil, value: settings.rows)
        .opacity(state.isExpanded || !hasWings ? 0 : 1)
        .allowsHitTesting(false)
    }

    private var occupancy: IslandOccupancy? { library.occupancy }

    private var hasWings: Bool { occupancy != nil }

    private var islandContext: WidgetRenderContext {
        let allowed = occupancy.flatMap { occupant in
            library.widgets.first { $0.id == occupant.widgetID }?.permissions.media
        } ?? false
        return .nowPlaying(nowPlaying, artwork: allowed)
    }

    private var expandedSize: CGSize {
        settings.expandedSize(notch: state.metrics.size)
    }

    private var collapsedSize: CGSize {
        settings.collapsedSize(notch: state.metrics.size, hasWings: hasWings)
    }

    private var peekSize: CGSize {
        settings.peekSize(notch: state.metrics.size, hasWings: hasWings)
    }

    private var bodySize: CGSize {
        if state.isExpanded { return expandedSize }
        if state.isHovered { return peekSize }
        return collapsedSize
    }

    private var shape: NotchShape {
        NotchShape(
            bodySize: bodySize,
            flareRadius: settings.flareRadius,
            bottomRadius: bottomRadius
        )
    }

    private var bottomRadius: CGFloat {
        if state.isExpanded { return settings.expandedBottomRadius }
        let resting = settings.restingBottomRadius(
            notch: state.metrics.size,
            hasWings: hasWings
        )
        // Peeking should never round *less* than the shape it grew out of.
        return state.isHovered ? max(settings.hoverPeekBottomRadius, resting) : resting
    }

    private var shadowOpacity: Double {
        if state.isExpanded || hasWings { return 0.5 }
        if state.isHovered { return 0.22 }
        return 0
    }

    /// Opening gets a little overshoot, which now reads as the bottom edge
    /// stretching past its resting point. Closing settles flat.
    private var transition: Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.18) }
        return state.isExpanded
            ? .spring(response: 0.38, dampingFraction: 0.74)
            : .spring(response: 0.30, dampingFraction: 0.92)
    }

    /// A snappy bounce into the peeked rest pose; settling back is flatter.
    private var hoverTransition: Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.12) }
        return state.isHovered
            ? .spring(response: 0.28, dampingFraction: 0.62)
            : .spring(response: 0.26, dampingFraction: 0.88)
    }
}
