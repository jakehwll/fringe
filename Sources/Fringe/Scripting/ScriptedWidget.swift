import Foundation
import Observation
import OSLog

/// One `.js` file, loaded and rendering.
@MainActor
@Observable
final class ScriptedWidget: Identifiable {
    let id: String
    let url: URL

    private(set) var name: String
    private(set) var span: WidgetSpan
    private(set) var padding: CGFloat = 8
    private(set) var settingsSpec: [WidgetSettingSpec] = []
    /// What the script asked for. `permissions` is this intersected with grants.
    private(set) var declaredPermissions = WidgetPermissions()
    private(set) var permissions = WidgetPermissions()
    private(set) var node: WidgetNode?
    private(set) var islandClaim: IslandClaim?
    private(set) var failure: String?
    /// Cached at load so the collapsed tick can skip widgets that never
    /// claimed the wings, without a property lookup into JavaScript.
    private(set) var definesIsland = false

    @ObservationIgnored private let runtime = ScriptRuntime()
    @ObservationIgnored private let store: WidgetDataStore
    @ObservationIgnored private let network = WidgetNetwork()
    @ObservationIgnored private var refresh: TimeInterval = 0
    @ObservationIgnored private var lastRender: Date = .distantPast
    @ObservationIgnored private var lastRenderedSpan: WidgetSpan?
    @ObservationIgnored private var lastIsland: Date = .distantPast
    @ObservationIgnored private var lastIslandContext: IslandScriptContext?
    @ObservationIgnored private var strikes = 0
    @ObservationIgnored private var settings: NotchSettings?

    /// Overruns tolerated before the widget is stopped for good. One is not
    /// enough: a render can lose its slice to a busy machine and come back
    /// fine, and killing a working widget over that would be worse than the
    /// dropped frame. Three is still bounded — 300ms at most, spread over
    /// three seconds — and a runaway loop never recovers, so it always spends
    /// them.
    private static let allowedStrikes = 3

    /// Load failures are stored rather than thrown: a broken script should show
    /// its error in the panel, not silently vanish from the grid.
    init(
        url: URL,
        mediaProvider: (() -> [String: Any]?)? = nil,
        settings: NotchSettings? = nil,
        dataRoot: URL = WidgetDataStore.defaultRoot()
    ) {
        self.url = url
        self.id = url.lastPathComponent
        self.name = url.deletingPathExtension().lastPathComponent
        self.span = .small
        self.settings = settings
        store = WidgetDataStore(widgetID: url.lastPathComponent, root: dataRoot)

        runtime.mediaProvider = mediaProvider
        runtime.storageGet = { [store] key in store.get(key) }
        runtime.storageSet = { [store] key, value in store.set(key, value: value) }
        runtime.fileRead = { [store] name in store.read(name: name) }
        runtime.fileWrite = { [store] name, contents in store.write(name: name, contents: contents) }
        runtime.fetchHandler = { [weak self] url, ttl in
            self?.network.lookup(url, ttl: ttl) ?? ["pending": true]
        }
        runtime.settingGet = { [weak self] key in
            guard let self else { return nil }
            let stored = self.settings?.widgetValue(self.id, key: key)
            guard let spec = self.settingsSpec.first(where: { $0.id == key }) else { return stored }
            return spec.resolved(stored)
        }
        network.onUpdate = { [weak self] in
            self?.forceRender()
        }

        do {
            let definition = try runtime.load(source: String(contentsOf: url, encoding: .utf8))
            name = definition.name
            span = definition.span
            refresh = definition.refresh
            padding = definition.padding
            settingsSpec = definition.settings
            declaredPermissions = definition.permissions
            definesIsland = runtime.definesIsland
            store.alignDeclaredPermissions(definition.permissions)
            applyGrants(render: false)
        } catch {
            // A script that cannot even load inside its budget is broken
            // outright; there is no later attempt that could go better.
            stop(error)
        }
    }

    func renderIfNeeded(now: Date = .now) {
        guard failure == nil else { return }

        let resolved = settings?.span(for: id, declared: span) ?? span
        let isFirstRender = node == nil
        let isDue = refresh > 0 && now.timeIntervalSince(lastRender) >= refresh
        let spanChanged = lastRenderedSpan != resolved
        guard isFirstRender || isDue || spanChanged else { return }

        lastRender = now
        lastRenderedSpan = resolved
        do {
            node = try runtime.render(timestamp: now.timeIntervalSince1970, span: resolved)
            strikes = 0
        } catch ScriptError.timedOut(let budget) {
            strikes += 1
            guard strikes >= Self.allowedStrikes else {
                Logger.scripts.notice(
                    "\(self.id, privacy: .public): overran \(Int(budget * 1000))ms budget (\(self.strikes)/\(Self.allowedStrikes))"
                )
                return
            }
            stop(ScriptError.timedOut(budget))
        } catch {
            stop(error)
        }
    }

    func forceRender() {
        lastRender = .distantPast
        lastRenderedSpan = nil
        renderIfNeeded()
        islandIfNeeded(now: .now, context: lastIslandContext ?? .zero, force: true)
    }

    /// Drop a cached claim without entering JavaScript. Used when the widget
    /// is disabled so a stale occupancy cannot linger, and so the next enable
    /// is treated as a first run.
    func invalidateIsland() {
        islandClaim = nil
        lastIsland = .distantPast
        lastIslandContext = nil
    }

    /// Collapsed wings keep ticking even when the board does not, but they
    /// follow the same `refresh` interval the tile asked for rather than a
    /// global one-second poke. `refresh: 0` is event-only: MagSafe, hover,
    /// wing size, or an explicit `force` from the host.
    func islandIfNeeded(
        now: Date = .now,
        context: IslandScriptContext,
        force: Bool = false
    ) {
        guard failure == nil, definesIsland else {
            islandClaim = nil
            return
        }

        let due = refresh > 0 && now.timeIntervalSince(lastIsland) >= refresh
        let changed = lastIslandContext != context
        guard islandClaim == nil || force || due || changed else { return }

        lastIsland = now
        lastIslandContext = context
        do {
            islandClaim = try runtime.island(context: context)
        } catch {
            islandClaim = nil
            Logger.scripts.notice(
                "\(self.id, privacy: .public) island: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func handleAction(_ name: String) {
        if name == "refresh" {
            network.invalidate()
        }
        runtime.dispatchAction(name)
        forceRender()
    }

    /// Recompute effective capabilities from Settings. Called after load and
    /// whenever the user flips a grant toggle.
    func applyGrants(render: Bool = true) {
        let granted = settings.map { $0.grantedCapabilities(for: id) }
        runtime.applyGrants(granted)
        permissions = runtime.permissions
        if !permissions.media {
            islandClaim = islandClaim.map { claim in
                var next = claim
                next.action = nil
                return next
            }
        }
        if render { forceRender() }
    }

    /// Takes the widget out of the render loop for good. `failure` is what
    /// stops it: both the tile and the settings list read it, so the user sees
    /// why it died rather than a widget that silently froze.
    private func stop(_ error: Error) {
        failure = error.localizedDescription
        Logger.scripts.error(
            "\(self.id, privacy: .public) stopped: \(error.localizedDescription, privacy: .private)"
        )
    }
}

extension WidgetSettingSpec {
    /// UserDefaults turns Bool into NSNumber. Without this, `notch.setting`
    /// would hand a script `1` for a toggle and `if (value)` would still
    /// work — until someone compared it to `true`.
    func resolved(_ stored: Any?) -> Any {
        switch kind {
        case .boolean:
            if let flag = stored as? Bool { return flag }
            if let number = stored as? NSNumber { return number.boolValue }
            return booleanDefault
        case .number:
            if let number = stored as? NSNumber { return number.doubleValue }
            return numberDefault
        case .string, .choice:
            if let string = stored as? String { return string }
            return stringDefault
        }
    }
}
