import Foundation
import IOKit.ps
import Testing

@testable import Fringe

@Suite("Widget node extras")
struct WidgetNodeExtraTests {
    @Test("A list keeps rows that have a title and drops the rest")
    func parsesList() {
        let node = WidgetNode.parse([
            "type": "list",
            "items": [
                ["title": "Mon", "subtitle": "Clear", "symbol": "sun.max.fill", "value": "22°"],
                ["subtitle": "no title"],
                ["title": "Tue", "value": "18°"],
            ],
        ])

        guard case .list(let list) = node else {
            Issue.record("expected a list")
            return
        }
        #expect(list.items.count == 2)
        #expect(list.items[0].title == "Mon")
        #expect(list.items[0].symbol == "sun.max.fill")
        #expect(list.items[1].value == "18°")
    }

    @Test("A symbol can ask for palette colours")
    func parsesPaletteSymbol() {
        let node = WidgetNode.parse([
            "type": "symbol",
            "name": "cloud.sun.fill",
            "size": 26,
            "rendering": "palette",
            "color": "#e8e8ed",
            "secondary": "#ffd60a",
            "tertiary": "#0a84ff",
        ])

        guard case .symbol(let symbol) = node else {
            Issue.record("expected a symbol")
            return
        }
        #expect(symbol.rendering == "palette")
        #expect(symbol.color == "#e8e8ed")
        #expect(symbol.secondary == "#ffd60a")
        #expect(symbol.tertiary == "#0a84ff")
        #expect(!symbol.fit)
    }

    @Test("A fitted symbol is a bounding box, not a font size")
    func parsesFittedSymbol() {
        let node = WidgetNode.parse([
            "type": "symbol",
            "name": "battery.100percent.bolt",
            "size": 11,
            "fit": true,
        ])

        guard case .symbol(let symbol) = node else {
            Issue.record("expected a symbol")
            return
        }
        #expect(symbol.fit)
        #expect(symbol.size == 11)
    }

    @Test("A chart reads numeric values and a kind")
    func parsesChart() {
        let node = WidgetNode.parse([
            "type": "chart",
            "values": [18, 20, 22, "21"],
            "kind": "bars",
            "height": 32,
            "fill": true,
            "color": "#64d2ff",
        ])

        guard case .chart(let chart) = node else {
            Issue.record("expected a chart")
            return
        }
        #expect(chart.values == [18, 20, 22, 21])
        #expect(chart.kind == .bars)
        #expect(chart.height == 32)
        #expect(chart.fill)
        #expect(chart.color == "#64d2ff")
    }

    @Test("An equaliser reads playing and size")
    func parsesEqualiser() {
        let node = WidgetNode.parse([
            "type": "equaliser",
            "playing": true,
            "size": 20,
        ])
        guard case .equaliser(let equaliser) = node else {
            Issue.record("expected an equaliser")
            return
        }
        #expect(equaliser.playing)
        #expect(equaliser.size == 20)
    }

    @Test("A tree deeper than the cap is dropped")
    func deepTreeIsDropped() {
        var node: [AnyHashable: Any] = ["type": "text", "value": "leaf"]
        for _ in 0..<12 {
            node = ["type": "stack", "axis": "vertical", "children": [node]]
        }
        #expect(!containsText(WidgetNode.parse(node), "leaf"))
    }

    private func containsText(_ node: WidgetNode?, _ value: String) -> Bool {
        switch node {
        case .text(let text): return text.value == value
        case .stack(let stack): return stack.children.contains { containsText($0, value) }
        case .button(let button): return containsText(button.child, value)
        default: return false
        }
    }

    @Test("An oversized font is clamped, not painted at a billion points")
    func hugeTextIsClamped() {
        let node = WidgetNode.parse([
            "type": "text",
            "value": "hi",
            "size": 1_000_000,
        ])
        guard case .text(let text) = node else {
            Issue.record("expected text")
            return
        }
        #expect(text.size == 96)
    }
}

@Suite("Widget settings")
struct WidgetSettingTests {
    @Test("Fields are parsed, sorted, and typed")
    func parsesFields() {
        let specs = WidgetSettingSpec.parse([
            "units": ["type": "choice", "options": ["C", "F"], "default": "C", "label": "Units"],
            "city": ["type": "string", "default": "Sydney", "label": "City"],
            "alerts": ["type": "boolean", "default": true],
        ])

        #expect(specs.map(\.id) == ["alerts", "city", "units"])
        #expect(specs.first { $0.id == "city" }?.stringDefault == "Sydney")
        #expect(specs.first { $0.id == "units" }?.options == ["C", "F"])
        #expect(specs.first { $0.id == "alerts" }?.booleanDefault == true)
    }

    @Test("A choice with no options is dropped rather than drawing an empty picker")
    func emptyChoiceIsDropped() {
        let specs = WidgetSettingSpec.parse([
            "bad": ["type": "choice", "default": "x"],
        ])
        #expect(specs.isEmpty)
    }
}

@Suite("Widget network policy")
struct WidgetNetworkPolicyTests {
    @Test("https with a public host is allowed")
    func httpsIsAllowed() {
        #expect(WidgetNetwork.allowedURL("https://api.open-meteo.com/v1/forecast") != nil)
        #expect(WidgetNetwork.allowedURL("https://1.1.1.1/") != nil)
    }

    @Test("Anything that is not https is refused")
    func nonHttpsIsRefused() {
        #expect(WidgetNetwork.allowedURL("http://example.com") == nil)
        #expect(WidgetNetwork.allowedURL("file:///etc/passwd") == nil)
        #expect(WidgetNetwork.allowedURL("https://") == nil)
        #expect(WidgetNetwork.allowedURL("not a url") == nil)
    }

    @Test("The machine and the LAN are not the internet")
    func privateHostsAreRefused() {
        #expect(WidgetNetwork.allowedURL("https://127.0.0.1/") == nil)
        #expect(WidgetNetwork.allowedURL("https://localhost/x") == nil)
        #expect(WidgetNetwork.allowedURL("https://192.168.1.1/admin") == nil)
        #expect(WidgetNetwork.allowedURL("https://10.0.0.8/") == nil)
        #expect(WidgetNetwork.allowedURL("https://172.16.0.1/") == nil)
        #expect(WidgetNetwork.allowedURL("https://169.254.1.1/") == nil)
        #expect(WidgetNetwork.allowedURL("https://router.local/") == nil)
        #expect(WidgetNetwork.allowedURL("https://[::1]/") == nil)
        #expect(WidgetNetwork.allowedURL("https://[fd12:3456:789a::1]/") == nil)
        #expect(WidgetNetwork.allowedURL("https://[::ffff:192.168.1.1]/") == nil)
        #expect(WidgetNetwork.allowedURL("https://127.1/") == nil)
        #expect(WidgetNetwork.allowedURL("https://[64:ff9b::c0a8:101]/") == nil)
        #expect(WidgetNetwork.allowedURL("https://[2002:c0a8:101::]/") == nil)
        #expect(WidgetNetwork.allowedURL("https://[::c0a8:101]/") == nil)
        #expect(WidgetNetwork.allowedURL("https://[2001:0:0:0:0:0:3f57:fefe]/") == nil)
    }

    @Test("A public 6to4 or NAT64 embedding of a public IPv4 is still public")
    func publicIPv6EmbeddingsAreAllowed() {
        #expect(WidgetNetwork.allowedURL("https://[2002:0808:0808::]/") != nil)
        #expect(WidgetNetwork.allowedURL("https://[64:ff9b::808:808]/") != nil)
    }

    @Test("TTL is capped and non-finite values fall back")
    func ttlIsClamped() {
        #expect(WidgetNetwork.clampedTTL(300) == 300)
        #expect(WidgetNetwork.clampedTTL(1_000_000) == WidgetNetwork.maxTTL)
        #expect(WidgetNetwork.clampedTTL(-5) == 0)
        #expect(WidgetNetwork.clampedTTL(.nan) == WidgetNetwork.defaultTTL)
        #expect(WidgetNetwork.clampedTTL(.infinity) == WidgetNetwork.defaultTTL)
    }

    @Test("A public IPv4 is allowed; 172.15 is not RFC1918")
    func publicIPv4IsAllowed() {
        #expect(WidgetNetwork.allowedURL("https://172.15.0.1/") != nil)
        #expect(WidgetNetwork.resolvesToPublicInternet("1.1.1.1"))
        #expect(!WidgetNetwork.resolvesToPublicInternet("192.168.0.1"))
        #expect(!WidgetNetwork.resolvesToPublicInternet("localhost"))
    }

    @Test("Deep JSON is refused rather than walked unbounded")
    func jsonDepthIsCapped() {
        #expect(WidgetNetwork.cappedJSON("leaf", depth: WidgetNetwork.maxJSONDepth + 1) == nil)
        let shallow = WidgetNetwork.cappedJSON(["ok": true])
        #expect((shallow as? [String: Bool])?["ok"] == true
            || (shallow as? [String: NSNumber])?["ok"]?.boolValue == true)
    }
}

@Suite("Media helper integrity")
struct MediaHelperIntegrityTests {
    @Test("A path outside the app bundle is not a trusted helper")
    func outsideBundleIsRejected() {
        let root = URL(fileURLWithPath: "/Applications/Fringe.app")
        let other = FileManager.default.temporaryDirectory.appending(path: "MediaRemoteAdapter")
        #expect(!MediaRemoteAdapterClient.isTrustedHelper(other, root: root))
    }

    @Test("A file inside the given root is trusted if it exists and is not a symlink")
    func fileInsideRootIsTrusted() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FringeHelper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "MediaRemoteAdapter")
        try Data("ok".utf8).write(to: file)
        #expect(MediaRemoteAdapterClient.isTrustedHelper(file, root: root))
    }
}

@Suite("Widget permissions")
struct WidgetPermissionTests {
    private func textValue(_ node: WidgetNode?) -> String? {
        guard case .text(let text) = node else { return nil }
        return text.value
    }

    @Test("Mixing network with media or battery is a load error")
    func mixedPermissionsFailToLoad() {
        let runtime = ScriptRuntime()
        do {
            _ = try runtime.load(source: """
                widget({
                  name: "Gist",
                  permissions: { network: true, media: true },
                  render: function () { return text("no"); }
                });
                """)
            Issue.record("expected mixed permissions to throw")
        } catch ScriptError.mixedPermissions {
            // The whole point.
        } catch {
            Issue.record("wrong error: \(error)")
        }

        do {
            _ = try runtime.load(source: """
                widget({
                  name: "Gist",
                  permissions: { network: true, battery: true },
                  render: function () { return text("no"); }
                });
                """)
            Issue.record("expected mixed permissions to throw")
        } catch ScriptError.mixedPermissions {
            // Same split.
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("A network widget cannot read media, even when the host has a session")
    func networkCannotReadMedia() throws {
        let runtime = ScriptRuntime()
        runtime.mediaProvider = { ["title": "Secret Track"] }
        _ = try runtime.load(source: """
            widget({
              name: "Weatherish",
              permissions: { network: true },
              render: function () {
                var media = notch.media();
                return text(media && media.title ? media.title : "none");
              }
            });
            """)
        #expect(textValue(try runtime.render(timestamp: 0)) == "none")
    }

    @Test("A media widget can read the session and cannot fetch")
    func mediaCannotFetch() throws {
        let runtime = ScriptRuntime()
        runtime.mediaProvider = { ["title": "Secret Track"] }
        runtime.fetchHandler = { _, _ in ["ok": true] }
        _ = try runtime.load(source: """
            widget({
              name: "Player",
              permissions: { media: true },
              render: function () {
                var media = notch.media();
                var remote = notch.fetch("https://example.com/");
                return text((media && media.title ? media.title : "none") + ":" + (remote.error || "ok"));
              }
            });
            """)
        #expect(
            textValue(try runtime.render(timestamp: 0))
                == "Secret Track:This widget has no network permission"
        )
    }

    @Test("Without a declaration, battery and fetch are both closed")
    func undeclaredIsClosed() throws {
        let runtime = ScriptRuntime()
        runtime.fetchHandler = { _, _ in ["ok": true] }
        _ = try runtime.load(source: """
            widget({
              name: "Clockish",
              render: function () {
                var power = notch.battery();
                var remote = notch.fetch("https://example.com/");
                return text((power ? "hit" : "null") + ":" + (remote.error ? "blocked" : "ok"));
              }
            });
            """)
        #expect(textValue(try runtime.render(timestamp: 0)) == "null:blocked")
    }

    @Test("A playPause island action is dropped without media permission")
    func islandActionNeedsMedia() throws {
        let runtime = ScriptRuntime()
        _ = try runtime.load(source: """
            widget({
              name: "Wings",
              render: function () { return text("hi"); },
              island: function () {
                return { priority: 1, left: text("L"), right: text("R"), action: "playPause" };
              }
            });
            """)
        let claim = try runtime.island(context: .zero)
        #expect(claim?.action == nil)
    }

    @Test("Parse treats missing and false as denied")
    func parseFlags() {
        #expect(WidgetPermissions.parse(nil) == WidgetPermissions())
        #expect(WidgetPermissions.parse(["network": true]) == WidgetPermissions(network: true))
        #expect(
            WidgetPermissions.parse(["network": true, "media": true]).mixesNetworkWithSecrets
        )
        #expect(!WidgetPermissions.parse(["battery": true]).mixesNetworkWithSecrets)
        #expect(
            WidgetPermissions(network: true, media: true)
                .intersection(WidgetPermissions(network: true)).media == false
        )
        #expect(WidgetPermissions.fromKeys(["network"]).network)
        #expect(!WidgetPermissions.fromKeys(nil).network)
    }

    @Test("Grants can deny a declared capability after load")
    func grantsRestrictHostCalls() throws {
        let runtime = ScriptRuntime()
        runtime.mediaProvider = { ["title": "Secret Track"] }
        _ = try runtime.load(source: """
            widget({
              name: "Player",
              permissions: { media: true },
              render: function () {
                var media = notch.media();
                return text(media && media.title ? media.title : "none");
              }
            });
            """)
        runtime.applyGrants(WidgetPermissions())
        #expect(textValue(try runtime.render(timestamp: 0)) == "none")
        runtime.applyGrants(WidgetPermissions(media: true))
        #expect(textValue(try runtime.render(timestamp: 0)) == "Secret Track")
    }
}

@Suite("Widget data store")
struct WidgetDataStoreTests {
    private func scratch() -> WidgetDataStore {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FringeTests-\(UUID().uuidString)")
        return WidgetDataStore(widgetID: "weather.js", root: root)
    }

    @Test("Storage round-trips JSON values")
    func storageRoundTrip() {
        let store = scratch()
        store.set("city", value: "Lisbon")
        store.set("temps", value: [18, 20, 22])
        #expect(store.get("city") as? String == "Lisbon")
        #expect(store.get("temps") as? [Int] == [18, 20, 22] || (store.get("temps") as? [NSNumber])?.map(\.intValue) == [18, 20, 22])
    }

    @Test("A slash or a parent directory is not a filename")
    func filenamesAreSandboxed() {
        #expect(!WidgetDataStore.isSafeFilename("../secrets"))
        #expect(!WidgetDataStore.isSafeFilename("foo/bar.json"))
        #expect(!WidgetDataStore.isSafeFilename(".hidden"))
        #expect(!WidgetDataStore.isSafeFilename("storage.json"))
        #expect(WidgetDataStore.isSafeFilename("notes.txt"))
        #expect(WidgetDataStore.fileURL(name: "../x", in: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test("A widget id cannot escape its folder")
    func widgetIDIsAComponent() {
        #expect(WidgetDataStore.safeComponent("foo/../bar.js") == "bar.js")
        #expect(WidgetDataStore.safeComponent("weather.js") == "weather.js")
    }

    @Test("Changing declared permissions wipes the store")
    func permissionChangeWipesStore() {
        let store = scratch()
        store.alignDeclaredPermissions(WidgetPermissions(media: true))
        store.set("title", value: "Secret Track")
        #expect(store.get("title") as? String == "Secret Track")

        store.alignDeclaredPermissions(WidgetPermissions(network: true))
        #expect(store.get("title") == nil)
    }

    @Test("The same permission set leaves stored values alone")
    func samePermissionsKeepStore() {
        let store = scratch()
        store.alignDeclaredPermissions(WidgetPermissions(network: true))
        store.set("city", value: "Lisbon")
        store.alignDeclaredPermissions(WidgetPermissions(network: true))
        #expect(store.get("city") as? String == "Lisbon")
    }
}

@Suite("Script render context")
struct ScriptRenderContextTests {
    @Test("render is told the cell span, not the one the script declared")
    func renderReceivesSpan() throws {
        let runtime = ScriptRuntime()
        _ = try runtime.load(source: """
            widget({
              name: "Probe",
              span: [3, 2],
              render: function (ctx) {
                return text(String(ctx.rows) + "x" + String(ctx.columns));
              }
            });
            """)
        let node = try runtime.render(
            timestamp: 0,
            span: WidgetSpan(columns: 4, rows: 1)
        )
        guard case .text(let text) = node else {
            Issue.record("expected text, got \(String(describing: node))")
            return
        }
        #expect(text.value == "1x4")
    }

    @Test("island null is not a claim")
    func islandNullIsNoClaim() throws {
        let runtime = ScriptRuntime()
        _ = try runtime.load(source: """
            widget({
              name: "Quiet",
              render: function () { return text("hi"); },
              island: function () { return null; }
            });
            """)
        #expect(try runtime.island(context: .zero) == nil)
    }

    @Test("island returns left, right, and priority")
    func islandReturnsClaim() throws {
        let runtime = ScriptRuntime()
        _ = try runtime.load(source: """
            widget({
              name: "Wings",
              permissions: { media: true },
              render: function () { return text("hi"); },
              island: function (ctx) {
                return {
                  priority: ctx.pulse ? 80 : 20,
                  left: symbol("battery.50percent"),
                  right: text("64%"),
                  action: "playPause"
                };
              }
            });
            """)
        let claim = try runtime.island(context: IslandScriptContext(
            pulse: true, hover: false, side: 20, wing: 36
        ))
        #expect(claim?.priority == 80)
        #expect(claim?.action == "playPause")
        guard case .symbol(let symbol) = claim?.left else {
            Issue.record("expected a symbol on the left")
            return
        }
        #expect(symbol.name == "battery.50percent")
        guard case .text(let text) = claim?.right else {
            Issue.record("expected text on the right")
            return
        }
        #expect(text.value == "64%")
    }

    @Test("a widget with no island function does not claim")
    func missingIsland() throws {
        let runtime = ScriptRuntime()
        _ = try runtime.load(source: """
            widget({
              name: "Board only",
              render: function () { return text("hi"); }
            });
            """)
        #expect(!runtime.definesIsland)
        #expect(try runtime.island(context: .zero) == nil)
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
        let t0 = Date()

        probe.islandIfNeeded(now: t0, context: .zero)
        #expect(islandCount(probe) == 1)

        probe.islandIfNeeded(now: t0.addingTimeInterval(5), context: .zero)
        #expect(islandCount(probe) == 1)

        probe.islandIfNeeded(now: t0.addingTimeInterval(5.1), context: .zero, force: true)
        #expect(islandCount(probe) == 2)

        probe.islandIfNeeded(
            now: t0.addingTimeInterval(5.2),
            context: IslandScriptContext(pulse: true, hover: false, side: 20, wing: 36)
        )
        #expect(islandCount(probe) == 3)
    }

    @Test("refresh 1 polls island once a second")
    func liveIslandPolls() throws {
        let probe = try makeWidget(counterIsland.replacingOccurrences(of: "REFRESH", with: "1"))
        let t0 = Date()

        probe.islandIfNeeded(now: t0, context: .zero)
        #expect(islandCount(probe) == 1)

        probe.islandIfNeeded(now: t0.addingTimeInterval(0.5), context: .zero)
        #expect(islandCount(probe) == 1)

        probe.islandIfNeeded(now: t0.addingTimeInterval(1), context: .zero)
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
        ac: Bool = false,
        toEmpty: Int? = nil,
        toFull: Int? = nil
    ) -> [String: Any] {
        var info: [String: Any] = [
            kIOPSCurrentCapacityKey as String: current,
            kIOPSMaxCapacityKey as String: max,
            kIOPSIsChargingKey as String: charging,
            kIOPSIsChargedKey as String: charged,
            kIOPSPowerSourceStateKey as String: ac
                ? (kIOPSACPowerValue as String)
                : (kIOPSBatteryPowerValue as String),
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
                kIOPSMaxCapacityKey as String: 0,
            ]) == nil
        )
    }

    @Test("Charging reports minutes to full, not to empty")
    func chargingMinutes() {
        let snap = PowerSource.snapshot(from: info(
            charging: true,
            ac: true,
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
            ac: true,
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
            "left": ["type": "symbol", "name": "bolt.fill"],
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
            (id: "nowplaying.js", enabled: true, claim: claim(50, label: "media")),
            (id: "battery.js", enabled: false, claim: claim(100, label: "battery")),
        ])
        #expect(occupancy?.widgetID == "nowplaying.js")
    }

    @Test("No claims means no wings")
    func emptyBoard() {
        #expect(IslandOccupancy.resolve(from: [
            (id: "clock.js", enabled: true, claim: nil),
        ]) == nil)
        #expect(IslandClaim.winning([]) == nil)
    }
}
