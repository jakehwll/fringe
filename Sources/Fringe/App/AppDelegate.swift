import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = NotchState()
    private let settings = NotchSettings()
    private let library = ScriptLibrary()
    private let nowPlaying = NowPlayingController()
    private let battery = BatteryMonitor()

    private var notchWindowController: NotchWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        nowPlaying.start()
        battery.start()
        // Scripts reach now-playing through `notch.media()`, so the provider
        // has to be in place before any of them load.
        library.mediaProvider = { [weak nowPlaying] in nowPlaying?.scriptValue }
        library.settings = settings
        library.start()

        let settingsWindow = SettingsWindowController(
            settings: settings,
            state: state,
            library: library
        )
        settingsWindowController = settingsWindow

        let notchWindow = NotchWindowController(
            state: state,
            settings: settings,
            library: library,
            nowPlaying: nowPlaying,
            battery: battery
        ) { [weak self] in
            self?.settingsWindowController?.show()
        }
        notchWindowController = notchWindow

        // Keep the panel open for as long as its settings are being edited.
        settingsWindow.onVisibilityChange = { [weak self] isVisible in
            self?.notchWindowController?.setPinned(isVisible)
        }

        notchWindow.start()

        statusItemController = StatusItemController(windowController: notchWindow) { [weak self] in
            self?.settingsWindowController?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The media helper is a child process, not a daemon — it should not
        // outlive us waiting to die on a broken pipe.
        nowPlaying.stop()
        battery.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
