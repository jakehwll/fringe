import CoreGraphics
import Testing

@testable import Fringe

@Suite("Geometry report")
@MainActor
struct GeometryReportTests {
    private let screen = CGRect(x: -1512, y: 300, width: 1512, height: 982)
    private let metrics = NotchMetrics(size: CGSize(width: 185, height: 32), isPhysical: true)

    private func report(
        settings: NotchSettings = NotchSettings(defaults: scratchDefaults()),
        placements: [String: WidgetPlacement] = [:],
        unplaced: [String] = [],
        stored: [StoredPreference] = []
    ) -> GeometryReport {
        GeometryReport(
            screenName: "Built-in Retina Display",
            screenFrame: screen,
            backingScale: 2,
            metrics: metrics,
            settings: settings,
            placements: placements,
            unplaced: unplaced,
            stored: stored
        )
    }

    @Test("The report's board origin matches PanelGeometry's")
    func boardOriginAgrees() {
        let settings = NotchSettings(defaults: scratchDefaults())
        let snapshot = report(settings: settings)
        let geometry = PanelGeometry(
            screenFrame: screen,
            notchHeight: metrics.size.height,
            contentTopPadding: settings.contentTopPadding,
            boardSize: settings.grid.contentSize
        )

        #expect(snapshot.boardOrigin == geometry.boardOrigin)
        #expect(snapshot.boardSize == settings.grid.contentSize)
        #expect(snapshot.expanded == settings.expandedSize(notch: metrics.size))
        #expect(snapshot.collapsed == metrics.size)
        #expect(snapshot.isPhysical)
    }

    @Test("A pinned widget and a packed widget are labelled differently")
    func originIsVisible() {
        let settings = NotchSettings(defaults: scratchDefaults())
        settings.setPosition(GridSlot(column: 4, row: 1), for: "pinned.js")

        let snapshot = report(
            settings: settings,
            placements: [
                "pinned.js": WidgetPlacement(slot: GridSlot(column: 4, row: 1), span: .small),
                "packed.js": WidgetPlacement(slot: GridSlot(column: 0, row: 0), span: .wide),
            ],
            unplaced: ["overflow.js"]
        )

        let pinned = snapshot.widgets.first { $0.id == "pinned.js" }
        let packed = snapshot.widgets.first { $0.id == "packed.js" }
        let missing = snapshot.widgets.first { $0.id == "overflow.js" }

        #expect(pinned?.origin == .pinned)
        #expect(packed?.origin == .packed)
        #expect(missing?.origin == .unplaced)
        #expect(pinned?.detail.contains("pinned") == true)
        #expect(missing?.detail == "No room on the grid")
    }

    @Test("A foreign stored key is still in the dump")
    func dumpFlagsUnknownKeys() {
        let snapshot = report(
            stored: [
                StoredPreference(key: "columns", value: "6", isForeign: false),
                StoredPreference(key: "simulateNotch", value: "1", isForeign: true),
            ]
        )
        #expect(snapshot.plainText.contains("simulateNotch [unknown]: 1"))
        #expect(snapshot.plainText.contains("columns: 6"))
        #expect(snapshot.plainText.contains("measured"))
    }

    @Test("A stand-in notch is labelled as one")
    func standInIsLabelled() {
        let snapshot = GeometryReport(
            screenName: "Studio Display",
            screenFrame: screen,
            backingScale: 2,
            metrics: NotchMetrics(size: CGSize(width: 196, height: 32), isPhysical: false),
            settings: NotchSettings(defaults: scratchDefaults()),
            placements: [:],
            unplaced: [],
            stored: []
        )
        #expect(snapshot.notchSource == "Drawn stand-in")
        #expect(snapshot.plainText.contains("stand-in"))
        #expect(!snapshot.screenDescription.contains("notched"))
    }
}
