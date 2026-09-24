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
                ["title": "Tue", "value": "18°"]
            ]
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
            "tertiary": "#0a84ff"
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
            "fit": true
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
            "color": "#64d2ff"
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
            "size": 20
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
            "size": 1_000_000
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
            "alerts": ["type": "boolean", "default": true]
        ])

        #expect(specs.map(\.id) == ["alerts", "city", "units"])
        #expect(specs.first { $0.id == "city" }?.stringDefault == "Sydney")
        #expect(specs.first { $0.id == "units" }?.options == ["C", "F"])
        #expect(specs.first { $0.id == "alerts" }?.booleanDefault == true)
    }

    @Test("A choice with no options is dropped rather than drawing an empty picker")
    func emptyChoiceIsDropped() {
        let specs = WidgetSettingSpec.parse([
            "bad": ["type": "choice", "default": "x"]
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
