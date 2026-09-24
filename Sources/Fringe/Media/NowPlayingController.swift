import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import OSLog

extension Logger {
    static let media = Logger(subsystem: "me.hwll.fringe", category: "media")
}

/// Live now-playing session, fed by the Perl MediaRemote adapter.
///
/// Direct MediaRemote reads are gated to Apple-signed processes, so this app
/// never calls the framework itself. Perl is signed; the adapter dylib it
/// loads streams every session the system knows about — browsers included.
@MainActor
@Observable
final class NowPlayingController {
    private(set) var snapshot: NowPlayingSnapshot?

    /// A blurred copy of the current artwork, used to tint the equaliser.
    /// Produced once per track — the bars redraw 60 times a second, and
    /// blurring full-resolution artwork on every one of those is pure waste.
    private(set) var blurredArtwork: NSImage?

    @ObservationIgnored private var blurredSourceHash: Int?
    @ObservationIgnored private let adapter = MediaRemoteAdapterClient()
    @ObservationIgnored private var adapterArtwork: NSImage?
    @ObservationIgnored private var artworkIdentity: String?

    func start() {
        guard MediaRemoteAdapterClient.isInstalled else {
            Logger.media.error("media adapter not bundled")
            return
        }

        adapter.onArtwork = { [weak self] image in
            self?.adapterArtwork = image
        }
        adapter.onTrack = { [weak self] track in
            self?.apply(track)
        }
        adapter.onGaveUp = { [weak self] in
            self?.clear()
        }
        adapter.start()
    }

    func stop() {
        adapter.stop()
    }

    // MARK: - Transport

    func togglePlayPause() { adapter.send(.togglePlayPause) }
    func next() { adapter.send(.nextTrack) }
    func previous() { adapter.send(.previousTrack) }

    /// Named actions widget scripts can trigger through `button(...)`.
    func perform(_ action: String) {
        switch action {
        case "playPause": togglePlayPause()
        case "next": next()
        case "previous": previous()
        default: Logger.media.error("unknown widget action \(action, privacy: .public)")
        }
    }

    /// What `notch.media()` hands to scripts. Elapsed and progress are
    /// interpolated, so a script polling once a second still gets a scrubber
    /// that advances smoothly between reads.
    var scriptValue: [String: Any]? {
        guard let snapshot else { return nil }
        return [
            "title": snapshot.title,
            "artist": snapshot.artist,
            "album": snapshot.album,
            "isPlaying": snapshot.isPlaying,
            "duration": snapshot.duration,
            "elapsed": snapshot.elapsed(),
            "progress": snapshot.progress(),
            "hasArtwork": snapshot.artwork != nil
        ]
    }

    // MARK: - Adapter

    private func apply(_ track: MediaRemoteAdapterClient.Track?) {
        guard let track, !(track.title.isEmpty && track.artist.isEmpty) else {
            clear()
            return
        }

        let identity = track.artworkID ?? "\(track.title)|\(track.album)"
        if identity != artworkIdentity {
            artworkIdentity = identity
            refreshBlur(from: adapterArtwork, hash: identity.hashValue)
        }

        logIfChanged(track.title, artwork: adapterArtwork != nil)

        snapshot = NowPlayingSnapshot(
            title: track.title.isEmpty ? "Not Playing" : track.title,
            artist: track.artist,
            album: track.album,
            artwork: adapterArtwork,
            artworkHash: identity.hashValue,
            duration: track.duration,
            elapsed: track.elapsed,
            fetchedAt: track.timestamp,
            isPlaying: track.isPlaying,
            playbackRate: track.playbackRate == 0 ? 1 : track.playbackRate
        )
    }

    private func clear() {
        if snapshot != nil {
            Logger.media.log("now playing cleared")
        }
        snapshot = nil
        artworkIdentity = nil
        blurredArtwork = nil
        blurredSourceHash = nil
    }

    private func refreshBlur(from artwork: NSImage?, hash: Int) {
        guard hash != blurredSourceHash else { return }
        blurredSourceHash = hash
        blurredArtwork = artwork?.gaussianBlurred()
    }

    private func logIfChanged(_ title: String, artwork: Bool) {
        guard snapshot?.title != title else { return }
        Logger.media.log(
            "now playing: \(title, privacy: .private) (artwork: \(artwork))"
        )
    }
}

private extension NSImage {
    /// Heavily blurred copy, used as a colour source rather than as an image —
    /// the detail is irrelevant, only the palette survives.
    func gaussianBlurred() -> NSImage? {
        guard let data = tiffRepresentation, let source = CIImage(data: data) else { return nil }

        let filter = CIFilter.gaussianBlur()
        // Clamping first stops the blur sampling transparent pixels beyond the
        // edges, which would otherwise fade the borders out to nothing.
        filter.inputImage = source.clampedToExtent()
        filter.radius = Float(max(4, source.extent.width * 0.06))

        guard let output = filter.outputImage?.cropped(to: source.extent),
              let cgImage = CIContext().createCGImage(output, from: source.extent)
        else { return nil }

        return NSImage(cgImage: cgImage, size: source.extent.size)
    }
}

struct NowPlayingSnapshot: Equatable {
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
    var artworkHash: Int
    var duration: TimeInterval
    var elapsed: TimeInterval
    var fetchedAt: Date
    var isPlaying: Bool
    var playbackRate: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.artworkHash == rhs.artworkHash
            && lhs.duration == rhs.duration
            && lhs.elapsed == rhs.elapsed
            && lhs.fetchedAt == rhs.fetchedAt
            && lhs.isPlaying == rhs.isPlaying
            && lhs.playbackRate == rhs.playbackRate
    }

    /// Interpolates between polls so the scrubber moves smoothly.
    func elapsed(at date: Date = .now) -> TimeInterval {
        guard isPlaying, playbackRate > 0 else { return elapsed }
        let live = elapsed + date.timeIntervalSince(fetchedAt) * playbackRate
        if duration > 0 { return min(duration, max(0, live)) }
        return max(0, live)
    }

    func progress(at date: Date = .now) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed(at: date) / duration))
    }
}
