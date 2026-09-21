import AppKit

/// Process entry point.
///
/// `NSApplication.delegate` is a weak reference, so the delegate is kept alive by
/// this stack frame — `run()` only returns once the app is quitting.
@main
enum FringeApplication {
    @MainActor
    static func main() {
        // JavaScriptCore reads these when the first VM is created. Widgets
        // are user-authored; JIT in an unsandboxed process is a 0-day away
        // from user-level code execution, and a render that builds a node
        // tree does not need it.
        setenv("JSC_useJIT", "0", 1)
        setenv("JSC_useDFGJIT", "0", 1)
        setenv("JSC_useFTLJIT", "0", 1)

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
