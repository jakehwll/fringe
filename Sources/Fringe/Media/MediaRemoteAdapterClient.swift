import AppKit
import Foundation
import OSLog
import Security

/// Now-playing from MediaRemote, by way of a helper running inside
/// `/usr/bin/perl`.
///
/// Reading another app's now-playing metadata is gated to Apple-signed
/// callers, so this process cannot call MediaRemote itself. Perl is
/// Apple-signed; a small adapter dylib loaded into it makes the same calls
/// and streams the results back as JSON lines. That sees *everything* the
/// system knows about — browsers, Podcasts, IINA — not just scriptable players.
@MainActor
final class MediaRemoteAdapterClient {
    /// Same numeric values `MRMediaRemoteSendCommand` expects.
    enum Command: UInt32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval
        var elapsed: TimeInterval
        var playbackRate: Double
        var isPlaying: Bool
        var timestamp: Date
        var artworkID: String?
    }

    /// Fires with nil when nothing is playing.
    var onTrack: ((Track?) -> Void)?
    /// Artwork arrives only when it changes, so the caller keeps the last one.
    var onArtwork: ((NSImage?) -> Void)?
    /// The helper kept dying and will not be restarted again.
    var onGaveUp: (() -> Void)?

    private(set) var isRunning = false

    private var process: Process?
    private var buffer = Data()
    private var restarts = 0
    private var isStopping = false

    private static let maximumRestarts = 5

    // MARK: - Availability

    private static var resources: (script: URL, framework: URL)? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let bundle = Bundle.main.bundleURL
        let script = resources.appending(path: "mediaremote-adapter.pl")
        let framework = resources.appending(path: "MediaRemoteAdapter.framework")
        let binary = framework.appending(path: "MediaRemoteAdapter")

        // The helper is loaded into Apple-signed perl. A symlink or a file
        // outside this bundle would be code execution in that process.
        guard isTrustedHelper(script, root: bundle),
              isTrustedHelper(binary, root: bundle),
              hasCodeSignature(binary)
        else { return nil }

        return (script, framework)
    }

    /// Resolved path must stay inside the app bundle, and must not be a symlink.
    nonisolated static func isTrustedHelper(_ url: URL, root: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }

    nonisolated static func hasCodeSignature(_ url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return false }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSBasicValidateOnly),
            nil
        ) == errSecSuccess
    }

    static var isInstalled: Bool { resources != nil }

    // MARK: - Streaming

    func start() {
        guard !isRunning, !isStopping, let resources = Self.resources else { return }

        buffer.removeAll()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.script.path, resources.framework.path, "stream"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.ingest(chunk) }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.scheduleRestart()
            }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
            Logger.media.log("media adapter started")
        } catch {
            Logger.media.error("could not start media adapter: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        isStopping = true
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// The helper outlives a crash of whatever it was talking to, but not a
    /// crash of its own. Restarts are capped so a permanently broken adapter
    /// does not spawn processes forever.
    private func scheduleRestart() {
        guard !isStopping else { return }

        guard restarts < Self.maximumRestarts else {
            Logger.media.error("media adapter exited too many times; giving up")
            onGaveUp?()
            return
        }

        restarts += 1
        let delay = Double(restarts) * 2
        Logger.media.error("media adapter exited; restarting in \(delay, format: .fixed(precision: 0))s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.start()
        }
    }

    /// One-shot helper process. Commands are rare, so paying for a launch is
    /// cheaper than keeping a second pipe open and writing a protocol for it.
    func send(_ command: Command) {
        guard let resources = Self.resources else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            resources.script.path,
            resources.framework.path,
            "send",
            String(command.rawValue)
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }

    // MARK: - Parsing

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)

        // The adapter emits one JSON object per line; a read can land
        // mid-object, so only whole lines are parsed.
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }

        // It spoke, so whatever made the last one die was not permanent.
        restarts = 0

        if object["idle"] as? Bool == true {
            onTrack?(nil)
            onArtwork?(nil)
            return
        }

        if let encoded = object["artwork"] as? String,
           let data = Data(base64Encoded: encoded) {
            onArtwork?(NSImage(data: data))
        }

        let stamp = object["timestamp"] as? Double
        onTrack?(
            Track(
                title: object["title"] as? String ?? "",
                artist: object["artist"] as? String ?? "",
                album: object["album"] as? String ?? "",
                duration: object["duration"] as? Double ?? 0,
                elapsed: object["elapsed"] as? Double ?? 0,
                playbackRate: object["playbackRate"] as? Double ?? 1,
                isPlaying: object["isPlaying"] as? Bool ?? false,
                timestamp: stamp.map(Date.init(timeIntervalSince1970:)) ?? .now,
                artworkID: object["artworkID"] as? String
            )
        )
    }
}
