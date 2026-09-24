import Foundation
import IOKit.ps
import Testing

@testable import Fringe

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
        let temps = store.get("temps")
        let numbers = (temps as? [NSNumber])?.map(\.intValue)
        #expect(temps as? [Int] == [18, 20, 22] || numbers == [18, 20, 22])
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
