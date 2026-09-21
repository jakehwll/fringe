import AppKit
import Observation

/// Watches the scripts folder and keeps a live set of widgets from it.
@MainActor
@Observable
final class ScriptLibrary {
    private(set) var widgets: [ScriptedWidget] = []

    let folder: URL

    /// Backs `notch.media()` in every script. Set before `start()`.
    var mediaProvider: (() -> [String: Any]?)?

    /// User-facing widget settings. Set before `start()` so `notch.setting`
    /// has somewhere to read from on the first render.
    var settings: NotchSettings?

    /// Facts `island()` needs from the host. Set before `start()`.
    var islandContext: () -> IslandScriptContext = { .zero }

    /// Who currently owns the collapsed wings. Nil is just the cutout.
    private(set) var occupancy: IslandOccupancy?

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var fingerprint: [String: Date] = [:]

    static let defaultFolder = AppSupport.folder("Widgets")

    init(folder: URL = ScriptLibrary.defaultFolder) {
        self.folder = folder
    }

    /// Widgets arranged by a saved order of filenames. Scripts the order has
    /// never seen — newly added files — fall in after the known ones,
    /// alphabetically, rather than jumping to the front.
    func widgets(orderedBy order: [String]) -> [ScriptedWidget] {
        let rank = Dictionary(
            (order.isEmpty ? ExampleScripts.filenames : order)
                .enumerated()
                .map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return widgets.sorted { lhs, rhs in
            let left = rank[lhs.id] ?? Int.max
            let right = rank[rhs.id] ?? Int.max
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    func start() {
        seedFolderIfMissing()
        reload()

        // One timer covers both jobs: noticing edited scripts, and asking
        // widgets that opted into a refresh interval to run again. Static
        // scripts (`refresh: 0`, no `island`) are skipped on the tick itself.
        let ticker = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Board tiles only re-render while the panel is open. Island widgets
    /// keep their own cadence either way — that is what the collapsed wings
    /// are for — but a script with nothing to show there is left asleep.
    func setActive(_ active: Bool) {
        isActive = active
        if active {
            renderAll()
        }
    }

    func reload() {
        fingerprint = currentFingerprint()
        widgets = load(scriptURLs())
        renderAll()
        refreshIslands()
    }

    private func load(_ urls: [URL]) -> [ScriptedWidget] {
        urls.map {
            ScriptedWidget(url: $0, mediaProvider: mediaProvider, settings: settings)
        }
    }

    func revealInFinder() {
        seedFolderIfMissing()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    // MARK: - Private

    private func tick() {
        // Editors save in different ways — some replace the file, some write in
        // place — so compare modification dates rather than trusting FS events.
        let latest = currentFingerprint()
        if latest != fingerprint {
            fingerprint = latest
            widgets = load(scriptURLs())
        }
        if isActive {
            renderAll()
        }
        refreshIslands()
    }

    /// `island()` is the one script entry that still runs while the board is
    /// asleep. Widgets that never defined it, and widgets the user has
    /// disabled, are not entered at all. `force` is for host events (hover,
    /// MagSafe, a track starting) that should not wait out a refresh interval.
    func refreshIslands(force: Bool = false) {
        let now = Date()
        let context = islandContext()
        for widget in widgets {
            let enabled = settings?.isEnabled(widget.id) ?? true
            if !enabled {
                widget.invalidateIsland()
                continue
            }
            guard widget.definesIsland else { continue }
            widget.islandIfNeeded(now: now, context: context, force: force)
        }
        let next = IslandOccupancy.resolve(
            from: widgets.map {
                (
                    id: $0.id,
                    enabled: settings?.isEnabled($0.id) ?? true,
                    claim: $0.islandClaim
                )
            }
        )
        if occupancy != next {
            occupancy = next
        }
    }

    private func renderAll() {
        let now = Date()
        for widget in widgets {
            widget.renderIfNeeded(now: now)
        }
    }

    private func scriptURLs() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return (contents ?? [])
            .filter { $0.pathExtension.lowercased() == "js" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func currentFingerprint() -> [String: Date] {
        var result: [String: Date] = [:]
        for url in scriptURLs() {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            result[url.lastPathComponent] = modified ?? .distantPast
        }
        return result
    }

    /// Writes any example that is not already on disk, rather than only
    /// populating an absent folder. Per-file means a deleted example comes
    /// back, and an edited one is never overwritten.
    private func seedFolderIfMissing() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for example in ExampleScripts.all {
            let destination = folder.appending(path: example.filename)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? example.source.write(to: destination, atomically: true, encoding: .utf8)
        }
    }
}
