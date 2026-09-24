import Foundation
import IOKit.ps
import Testing

@testable import Fringe

@Suite("Board render cadence")
@MainActor
struct BoardRenderCadenceTests {
    private func makeWidget(_ source: String, settings: NotchSettings? = nil) throws -> ScriptedWidget {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "FringeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "probe.js")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return ScriptedWidget(url: url, settings: settings, dataRoot: folder.appending(path: "data"))
    }

    private func textValue(_ widget: ScriptedWidget) -> String? {
        guard case .text(let text) = widget.node else { return nil }
        return text.value
    }

    private let spanProbe = """
        widget({
          name: "Probe",
          span: [3, 2],
          refresh: 60,
          render: function (ctx) {
            return text(String(ctx.rows) + "x" + String(ctx.columns));
          }
        });
        """

    @Test("A live cell resize rerenders immediately, even before settings commit")
    func liveCellResizeSkipsTheTick() throws {
        let settings = NotchSettings(defaults: scratchDefaults())
        let probe = try makeWidget(spanProbe, settings: settings)
        let start = Date()

        probe.renderIfNeeded(now: start)
        #expect(textValue(probe) == "2x3")

        settings.setSpan(WidgetSpan(columns: 3, rows: 2), for: probe.id)
        probe.renderIfNeeded(now: start.addingTimeInterval(1), span: WidgetSpan(columns: 1, rows: 1))
        #expect(textValue(probe) == "1x1")
    }

    @Test("A later tick keeps the live cell instead of reverting to settings")
    func tickDoesNotRevertLiveSpan() throws {
        let settings = NotchSettings(defaults: scratchDefaults())
        let probe = try makeWidget(spanProbe, settings: settings)
        let start = Date()

        probe.renderIfNeeded(now: start)
        settings.setSpan(WidgetSpan(columns: 3, rows: 2), for: probe.id)
        probe.renderIfNeeded(now: start.addingTimeInterval(1), span: WidgetSpan(columns: 1, rows: 1))
        #expect(textValue(probe) == "1x1")

        probe.renderIfNeeded(now: start.addingTimeInterval(61))
        #expect(textValue(probe) == "1x1")
    }

    @Test("refresh 0 still rerenders when the cell changes")
    func staticWidgetRerendersOnResize() throws {
        let probe = try makeWidget("""
            widget({
              name: "Probe",
              span: [2, 2],
              refresh: 0,
              render: function (ctx) {
                return text(String(ctx.rows) + "x" + String(ctx.columns));
              }
            });
            """)
        let start = Date()

        probe.renderIfNeeded(now: start)
        #expect(textValue(probe) == "2x2")

        probe.renderIfNeeded(now: start.addingTimeInterval(30), span: WidgetSpan(columns: 3, rows: 1))
        #expect(textValue(probe) == "1x3")
    }
}

@Suite("Island cadence")
@MainActor
struct IslandCadenceTests {
    private func makeWidget(_ source: String) throws -> ScriptedWidget {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "FringeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "probe.js")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return ScriptedWidget(url: url, dataRoot: folder.appending(path: "data"))
    }

    private func islandCount(_ widget: ScriptedWidget) -> Int {
        guard case .text(let text) = widget.islandClaim?.left else { return 0 }
        return Int(text.value) ?? 0
    }

    private let counterIsland = """
        widget({
          name: "Probe",
          refresh: REFRESH,
          render: function () { return text("hi"); },
          island: function () {
            var n = Number(notch.load("n") || 0) + 1;
            notch.store("n", n);
            return { priority: 1, left: text(String(n)), right: text("x") };
          }
        });
        """

    @Test("A script with no island is not entered")
    func missingIslandIsSkipped() throws {
        let probe = try makeWidget("""
            widget({
              name: "Hello",
              refresh: 0,
              render: function () { return text("hi"); }
            });
            """)
        #expect(!probe.definesIsland)
        probe.islandIfNeeded(now: .now, context: .zero, force: true)
        #expect(probe.islandClaim == nil)
    }

    @Test("refresh 0 only reruns island on the first call, a force, or a context change")
    func staticIslandIsEventOnly() throws {
        let probe = try makeWidget(counterIsland.replacingOccurrences(of: "REFRESH", with: "0"))
        let start = Date()

        probe.islandIfNeeded(now: start, context: .zero)
        #expect(islandCount(probe) == 1)

        probe.islandIfNeeded(now: start.addingTimeInterval(5), context: .zero)
        #expect(islandCount(probe) == 1)

        probe.islandIfNeeded(now: start.addingTimeInterval(5.1), context: .zero, force: true)
        #expect(islandCount(probe) == 2)

        probe.islandIfNeeded(
            now: start.addingTimeInterval(5.2),
            context: IslandScriptContext(pulse: true, hover: false, side: 20, wing: 36)
        )
        #expect(islandCount(probe) == 3)
    }

    @Test("refresh 1 polls island once a second")
    func liveIslandPolls() throws {
        let probe = try makeWidget(counterIsland.replacingOccurrences(of: "REFRESH", with: "1"))
        let start = Date()

        probe.islandIfNeeded(now: start, context: .zero)
        #expect(islandCount(probe) == 1)

        probe.islandIfNeeded(now: start.addingTimeInterval(0.5), context: .zero)
        #expect(islandCount(probe) == 1)

        probe.islandIfNeeded(now: start.addingTimeInterval(1), context: .zero)
        #expect(islandCount(probe) == 2)
    }
}

@Suite("Power source snapshot")
struct PowerSourceTests {
    private func info(
        current: Int = 80,
        max: Int = 100,
        charging: Bool = false,
        charged: Bool = false,
        onAC: Bool = false,
        toEmpty: Int? = nil,
        toFull: Int? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            kIOPSCurrentCapacityKey as String: current,
            kIOPSMaxCapacityKey as String: max,
            kIOPSIsChargingKey as String: charging,
            kIOPSIsChargedKey as String: charged,
            kIOPSPowerSourceStateKey as String: onAC
                ? (kIOPSACPowerValue as String)
                : (kIOPSBatteryPowerValue as String)
        ]
        if let toEmpty { info[kIOPSTimeToEmptyKey as String] = toEmpty }
        if let toFull { info[kIOPSTimeToFullChargeKey as String] = toFull }
        return info
    }

    @Test("Level is current over max")
    func level() {
        let snap = PowerSource.snapshot(from: info(current: 37, max: 50))
        #expect(snap?.level == 0.74)
        #expect(snap?.isCharging == false)
        #expect(snap?.isAC == false)
    }

    @Test("A missing or empty pack is not a snapshot")
    func missingCapacity() {
        #expect(PowerSource.snapshot(from: [:]) == nil)
        #expect(
            PowerSource.snapshot(from: [
                kIOPSCurrentCapacityKey as String: 10,
                kIOPSMaxCapacityKey as String: 0
            ]) == nil
        )
    }

    @Test("Charging reports minutes to full, not to empty")
    func chargingMinutes() {
        let snap = PowerSource.snapshot(from: info(
            charging: true,
            onAC: true,
            toEmpty: 12,
            toFull: 48
        ))
        #expect(snap?.isCharging == true)
        #expect(snap?.isAC == true)
        #expect(snap?.minutes == 48)
    }

    @Test("On battery, minutes are time to empty")
    func dischargingMinutes() {
        let snap = PowerSource.snapshot(from: info(toEmpty: 95, toFull: 10))
        #expect(snap?.minutes == 95)
    }

    @Test("A calculating estimate is omitted rather than shown as -1")
    func unknownMinutes() {
        #expect(PowerSource.snapshot(from: info(toEmpty: -1))?.minutes == nil)
        #expect(PowerSource.snapshot(from: info(toEmpty: 65535))?.minutes == nil)
    }

    @Test("Fully charged on AC has no countdown")
    func chargedOnAC() {
        let snap = PowerSource.snapshot(from: info(
            current: 100,
            charged: true,
            onAC: true,
            toFull: 0
        ))
        #expect(snap?.isCharged == true)
        #expect(snap?.minutes == nil)
        #expect(snap?.scriptValue["minutes"] == nil)
    }
}

@Suite("Battery alerts")
struct BatteryAlertTests {
    @Test("A healthy pack on battery is silent")
    func healthyIsSilent() {
        #expect(BatteryAlert.crossing(percent: 54, plugged: false, already: []) == nil)
    }

    @Test("Crossing 20% warns once")
    func warnFiresOnce() {
        #expect(BatteryAlert.crossing(percent: 18, plugged: false, already: []) == 20)
        #expect(BatteryAlert.crossing(percent: 18, plugged: false, already: [20]) == nil)
    }

    @Test("Crossing 10% is a second, more urgent alert")
    func criticalFiresAfterWarn() {
        #expect(BatteryAlert.crossing(percent: 8, plugged: false, already: [20]) == 10)
    }

    @Test("Plugged in is never an alert, even at 5%")
    func pluggedIsSilent() {
        #expect(BatteryAlert.crossing(percent: 5, plugged: true, already: []) == nil)
        #expect(BatteryAlert.isRecovered(percent: 5, plugged: true))
    }

    @Test("Climbing back above 20% forgets what was posted")
    func recovery() {
        #expect(BatteryAlert.isRecovered(percent: 21, plugged: false))
        #expect(!BatteryAlert.isRecovered(percent: 20, plugged: false))
    }
}

@Suite("Charging pulse")
struct BatteryPulseTests {
    @Test("The first reading is a baseline, not a plug-in")
    func firstReadingIsSilent() {
        #expect(!BatteryPulse.shouldBegin(previous: nil, now: true))
        #expect(!BatteryPulse.shouldBegin(previous: nil, now: false))
    }

    @Test("Going on or off is a pulse")
    func edgeTriggers() {
        #expect(BatteryPulse.shouldBegin(previous: false, now: true))
        #expect(BatteryPulse.shouldBegin(previous: true, now: false))
    }

    @Test("Staying put is not")
    func steadyIsSilent() {
        #expect(!BatteryPulse.shouldBegin(previous: true, now: true))
        #expect(!BatteryPulse.shouldBegin(previous: false, now: false))
    }
}

@Suite("Island occupancy")
struct IslandOccupancyTests {
    private func claim(_ priority: Int, label: String) -> IslandClaim {
        IslandClaim(
            priority: priority,
            left: .symbol(SymbolNode(name: label)),
            right: .text(TextNode(value: label)),
            action: nil
        )
    }

    @Test("A missing or empty island is not a claim")
    func parseRequiresWings() {
        #expect(IslandClaim.parse(nil) == nil)
        #expect(IslandClaim.parse(["priority": 10]) == nil)
        #expect(IslandClaim.parse([
            "left": ["type": "symbol", "name": "bolt.fill"]
        ]) == nil)
    }

    @Test("Highest priority wins")
    func highestWins() {
        let media = claim(50, label: "media")
        let critical = claim(100, label: "battery")
        #expect(IslandClaim.winning([media, critical])?.priority == 100)
    }

    @Test("A disabled widget cannot occupy the island")
    func disabledIsSkipped() {
        let occupancy = IslandOccupancy.resolve(from: [
            IslandCandidate(id: "nowplaying.js", enabled: true, claim: claim(50, label: "media")),
            IslandCandidate(id: "battery.js", enabled: false, claim: claim(100, label: "battery"))
        ])
        #expect(occupancy?.widgetID == "nowplaying.js")
    }

    @Test("No claims means no wings")
    func emptyBoard() {
        #expect(IslandOccupancy.resolve(from: [
            IslandCandidate(id: "clock.js", enabled: true, claim: nil)
        ]) == nil)
        #expect(IslandClaim.winning([]) == nil)
    }
}
