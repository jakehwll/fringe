import Foundation
import Testing

@testable import Fringe

@Suite("Settings persistence")
@MainActor
struct NotchSettingsTests {
    @Test("A fresh install gets the default grid")
    func defaults() {
        let settings = NotchSettings(defaults: scratchDefaults())

        #expect(settings.columns == 6)
        #expect(settings.rows == 2)
        #expect(settings.widgetOrder.isEmpty)
        #expect(settings.widgetSpans.isEmpty)
        #expect(settings.widgetPositions.isEmpty)
        #expect(settings.disabledWidgets.isEmpty)
        #expect(settings.widgetValues.isEmpty)
        #expect(settings.widgetCapabilityGrants == ExampleScripts.bundledGrants)
    }

    @Test("Stored values are read back")
    func readsStoredValues() {
        let settings = NotchSettings(defaults: scratchDefaults([
            "columns": 8,
            "rows": 3,
            "widgetOrder": ["b.js", "a.js"],
            "disabledWidgets": ["c.js"],
        ]))

        #expect(settings.columns == 8)
        #expect(settings.rows == 3)
        #expect(settings.widgetOrder == ["b.js", "a.js"])
        #expect(settings.disabledWidgets == ["c.js"])
    }

    /// A stored value outside the range the UI allows would otherwise produce
    /// a grid the settings window cannot represent or undo.
    @Test("Out-of-range stored values are clamped on load", arguments: [
        (stored: 99, expected: 10),
        (stored: 0, expected: 3),
        (stored: -5, expected: 3),
    ])
    func clampsColumns(stored: Int, expected: Int) {
        let settings = NotchSettings(defaults: scratchDefaults(["columns": stored]))
        #expect(settings.columns == expected)
    }

    @Test("Out-of-range rows are clamped too")
    func clampsRows() {
        #expect(NotchSettings(defaults: scratchDefaults(["rows": 99])).rows == 4)
        #expect(NotchSettings(defaults: scratchDefaults(["rows": 0])).rows == 1)
    }

    /// The `simulateNotch` incident: a preference that had been removed from
    /// the UI stayed in `UserDefaults` and kept overriding the measured notch,
    /// with nothing on screen to show it was doing so.
    @Test("The retired simulateNotch preference is cleared off disk")
    func retiredPreferenceIsPurged() {
        let defaults = scratchDefaults(["simulateNotch": true])
        _ = NotchSettings(defaults: defaults)

        #expect(defaults.object(forKey: "simulateNotch") == nil)
    }

    @Test("Spans round-trip through their stored pair form")
    func spanRoundTrip() {
        let settings = NotchSettings(defaults: scratchDefaults())
        settings.setSpan(WidgetSpan(columns: 3, rows: 2), for: "a.js")

        #expect(settings.span(for: "a.js", declared: .small) == WidgetSpan(columns: 3, rows: 2))
    }

    @Test("A widget with no stored span keeps the one its script declared")
    func declaredSpanIsTheDefault() {
        let settings = NotchSettings(defaults: scratchDefaults())
        #expect(settings.span(for: "unknown.js", declared: .wide) == .wide)
    }

    @Test("A malformed stored span falls back to the declared one")
    func malformedSpanIsIgnored() {
        let settings = NotchSettings(defaults: scratchDefaults(["widgetSpans": ["a.js": [3]]]))
        #expect(settings.span(for: "a.js", declared: .tall) == .tall)
    }

    @Test("Positions round-trip, and clearing one restores packing")
    func positionRoundTrip() {
        let settings = NotchSettings(defaults: scratchDefaults())
        settings.setPosition(GridSlot(column: 4, row: 1), for: "a.js")
        #expect(settings.position(for: "a.js") == GridSlot(column: 4, row: 1))

        settings.clearPosition(for: "a.js")
        #expect(settings.position(for: "a.js") == nil)
    }

    @Test("Commit stores a fitted span so the next arrange does not bounce")
    func commitPersistsFittedPlacement() async {
        let defaults = scratchDefaults()
        let settings = NotchSettings(defaults: defaults)
        let fitted = WidgetPlacement(
            slot: GridSlot(column: 5, row: 0),
            span: WidgetSpan(columns: 1, rows: 2)
        )
        settings.commit(["player.js": fitted])

        #expect(settings.span(for: "player.js", declared: WidgetSpan(columns: 3, rows: 2)) == fitted.span)
        #expect(settings.position(for: "player.js") == fitted.slot)

        await Task.yield()

        let reloaded = NotchSettings(defaults: defaults)
        #expect(reloaded.span(for: "player.js", declared: WidgetSpan(columns: 3, rows: 2)) == fitted.span)
        #expect(reloaded.position(for: "player.js") == fitted.slot)
    }

    @Test("A malformed stored position is treated as absent")
    func malformedPositionIsIgnored() {
        let settings = NotchSettings(defaults: scratchDefaults(["widgetPositions": ["a.js": [1]]]))
        #expect(settings.position(for: "a.js") == nil)
    }

    @Test("Widgets are enabled unless explicitly switched off")
    func enablement() {
        let settings = NotchSettings(defaults: scratchDefaults())
        #expect(settings.isEnabled("a.js"))

        settings.setEnabled(false, for: "a.js")
        #expect(!settings.isEnabled("a.js"))

        settings.setEnabled(true, for: "a.js")
        #expect(settings.isEnabled("a.js"))
    }

    @Test("Resetting clears every stored arrangement, not just the grid")
    func resetClearsEverything() {
        let settings = NotchSettings(defaults: scratchDefaults())
        settings.columns = 9
        settings.rows = 4
        settings.widgetOrder = ["a.js"]
        settings.setSpan(.large, for: "a.js")
        settings.setPosition(GridSlot(column: 1, row: 1), for: "a.js")
        settings.setEnabled(false, for: "b.js")
        settings.setWidgetValue("Lisbon", widgetID: "weather.js", key: "city")

        settings.resetToDefaults()

        #expect(settings.columns == 6)
        #expect(settings.rows == 2)
        #expect(settings.widgetOrder.isEmpty)
        #expect(settings.widgetSpans.isEmpty)
        #expect(settings.widgetPositions.isEmpty)
        #expect(settings.disabledWidgets.isEmpty)
        #expect(settings.widgetValues.isEmpty)
        #expect(settings.widgetCapabilityGrants == ExampleScripts.bundledGrants)
    }

    @Test("A gist is not granted network until the user allows it")
    func gistStartsDenied() {
        let settings = NotchSettings(defaults: scratchDefaults())
        #expect(!settings.grantedCapabilities(for: "gist.js").network)
        settings.setGranted(WidgetPermissions(network: true), for: "gist.js")
        #expect(settings.grantedCapabilities(for: "gist.js").network)
    }

    @Test("Stored grants win over the bundled defaults")
    func storedGrantsWin() {
        let settings = NotchSettings(defaults: scratchDefaults([
            "widgetCapabilityGrants": ["weather.js": ["network"] as Any, "gist.js": ["media"]],
        ]))
        #expect(settings.grantedCapabilities(for: "weather.js").network)
        #expect(settings.grantedCapabilities(for: "gist.js").media)
        #expect(!settings.grantedCapabilities(for: "battery.js").battery)
    }

    @Test("The grid reflects the stored columns and rows")
    func gridFollowsPreferences() {
        let settings = NotchSettings(defaults: scratchDefaults(["columns": 4, "rows": 3]))
        let grid = settings.grid

        #expect(grid.columns == 4)
        #expect(grid.rows == 3)
        #expect(grid.contentSize.width == grid.length(cells: 4))
        #expect(grid.contentSize.height == grid.length(cells: 3))
    }

    @Test("Edits are written to disk, and a new instance reads them back")
    func writesAndReloads() async {
        let defaults = scratchDefaults()
        let settings = NotchSettings(defaults: defaults)
        settings.columns = 8
        settings.setPosition(GridSlot(column: 3, row: 1), for: "a.js")
        settings.setEnabled(false, for: "b.js")

        // Observation tracking saves on the next main-actor turn.
        await Task.yield()

        let reloaded = NotchSettings(defaults: defaults)
        #expect(reloaded.columns == 8)
        #expect(reloaded.position(for: "a.js") == GridSlot(column: 3, row: 1))
        #expect(!reloaded.isEnabled("b.js"))
    }
}

@Suite("Preference inventory")
struct PreferenceInventoryTests {
    @Test("Keys this build writes are not flagged")
    func knownKeysAreClean() {
        let entries = NotchSettings.inventory(of: [
            "columns": 6,
            "rows": 2,
            "widgetOrder": ["a.js"],
        ])
        #expect(entries.map(\.key) == ["columns", "rows", "widgetOrder"])
        #expect(entries.allSatisfy { !$0.isForeign })
    }

    /// The `simulateNotch` incident in the form it actually took: a key the
    /// current build does not write, sitting next to the real ones, with
    /// nothing to distinguish it.
    @Test("A retired key is flagged as foreign")
    func retiredKeyIsForeign() {
        let entries = NotchSettings.inventory(of: [
            "columns": 6,
            "simulateNotch": true,
        ])
        let stray = entries.first { $0.key == "simulateNotch" }
        #expect(stray?.isForeign == true)
        #expect(entries.first { $0.key == "columns" }?.isForeign == false)
    }

    @Test("Apple's own keys are ignored")
    func appleKeysAreDropped() {
        let entries = NotchSettings.inventory(of: [
            "AppleLanguages": ["en"],
            "NSInitialToolTipDelay": 0,
            "com.apple.something": 1,
            "columns": 6,
        ])
        #expect(entries.map(\.key) == ["columns"])
    }

    @Test("simulateNotch is not a key this build writes")
    func simulateNotchIsNotStored() {
        #expect(!NotchSettings.storedKeys.contains("simulateNotch"))
    }
}

@Suite("Derived panel sizes")
@MainActor
struct PanelSizeTests {
    private let notch = CGSize(width: 185, height: 32)

    @Test("The expanded panel is the grid plus its insets")
    func expandedSize() {
        let settings = NotchSettings(defaults: scratchDefaults())
        let size = settings.expandedSize(notch: notch)
        let content = settings.grid.contentSize

        #expect(size.width == content.width + settings.contentHorizontalPadding * 2)
        #expect(
            size.height
                == notch.height + settings.contentTopPadding + content.height
                + settings.contentBottomPadding
        )
    }

    /// The window is sized for the 10×4 ceiling so a live grid resize never
    /// has to move it. A 3×1 board and a 10×4 board share the same canvas.
    @Test("The window canvas is the largest grid, not the current one")
    func windowCanvasIgnoresCurrentGrid() {
        let small = NotchSettings(defaults: scratchDefaults(["columns": 3, "rows": 1]))
        let large = NotchSettings(defaults: scratchDefaults(["columns": 10, "rows": 4]))

        #expect(small.windowCanvasSize(notch: notch) == large.windowCanvasSize(notch: notch))
        #expect(small.windowCanvasSize(notch: notch) == large.expandedSize(notch: notch))
        #expect(small.windowOuterSize(notch: notch) == large.windowOuterSize(notch: notch))
    }

    /// The header has to clear the cutout on both sides (gear on the trailing
    /// edge, empty matching width on the leading), so a narrow grid cannot
    /// shrink the panel under it.
    @Test("A narrow grid still leaves room for the header either side of the notch")
    func headerFloor() {
        let settings = NotchSettings(defaults: scratchDefaults(["columns": 3]))
        let size = settings.expandedSize(notch: notch)

        #expect(size.width >= notch.width + settings.headerSideMinimum * 2)
    }

    @Test("With no media the collapsed island is exactly the cutout")
    func idleIslandMatchesCutout() {
        let settings = NotchSettings(defaults: scratchDefaults())
        #expect(settings.collapsedSize(notch: notch, hasWings: false) == notch)
    }

    /// The wings are built as content-plus-padding on each side, which is what
    /// keeps the silhouette symmetric about the hardware cutout.
    @Test("The media island grows by equal wings either side of the cutout")
    func islandIsSymmetric() {
        let settings = NotchSettings(defaults: scratchDefaults())
        let layout = settings.islandLayout(notch: notch)

        #expect(layout.size.width == notch.width + layout.wingWidth * 2)
        #expect(layout.wingWidth == layout.contentSide + settings.islandPadding * 2)
        #expect(layout.notchWidth == notch.width)
    }

    @Test("The island keeps the cutout's height so it cannot lip over the menu bar")
    func islandDoesNotHangBelowTheCutout() {
        let settings = NotchSettings(defaults: scratchDefaults())
        #expect(settings.islandLayout(notch: notch).size.height == notch.height)
    }

    @Test("Peeking grows the island in both axes")
    func peekGrowsBothAxes() {
        let settings = NotchSettings(defaults: scratchDefaults())
        let rest = settings.collapsedSize(notch: notch, hasWings: true)
        let peek = settings.peekSize(notch: notch, hasWings: true)

        #expect(peek.width == rest.width + settings.hoverPeekWidth)
        #expect(peek.height == rest.height + settings.hoverPeekHeight)
    }

    @Test("Island content is the cutout height minus the inset on both sides")
    func islandContentMatchesInset() {
        let settings = NotchSettings(defaults: scratchDefaults())
        let layout = settings.islandLayout(notch: notch)

        #expect(layout.contentSide == notch.height - settings.islandContentInset * 2)
        #expect(layout.size.height == notch.height)
    }
}

@Suite("Physical notch measurement")
struct NotchMeasurementTests {
    /// A 14-inch MacBook Pro: 1512pt wide, 32pt cutout, auxiliary areas
    /// filling everything either side of it.
    private let macbook = (
        width: CGFloat(1512),
        left: CGFloat(663.5),
        right: CGFloat(663.5),
        inset: CGFloat(32)
    )

    @Test("The cutout is whatever sits between the two auxiliary areas")
    func measuresTheGap() {
        let size = NotchMetrics.physicalSize(
            screenWidth: macbook.width,
            leftAuxiliary: macbook.left,
            rightAuxiliary: macbook.right,
            topInset: macbook.inset
        )
        #expect(size == CGSize(width: 185, height: 32))
    }

    @Test("No cutout means no measurement, not a guessed width")
    func missingCutoutIsNil() {
        #expect(
            NotchMetrics.physicalSize(
                screenWidth: 1512,
                leftAuxiliary: 1512,
                rightAuxiliary: 0,
                topInset: 0
            ) == nil
        )
        #expect(
            NotchMetrics.physicalSize(
                screenWidth: 1920,
                leftAuxiliary: nil,
                rightAuxiliary: nil,
                topInset: 0
            ) == nil
        )
    }

    @Test("A degenerate gap is refused rather than drawn as a sliver")
    func sliverIsRefused() {
        #expect(
            NotchMetrics.physicalSize(
                screenWidth: 1512,
                leftAuxiliary: 756,
                rightAuxiliary: 756,
                topInset: 32
            ) == nil
        )
    }
}
