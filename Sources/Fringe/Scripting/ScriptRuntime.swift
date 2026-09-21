import Foundation
import JavaScriptCore
import OSLog

/// What a script declared about itself when it called `widget({...})`.
struct ScriptDefinition {
    var name: String
    var span: WidgetSpan
    /// Seconds between re-renders. Zero means render once and leave it.
    var refresh: TimeInterval
    /// Inset between the tile and the script's tree. Set it to zero for a
    /// full-bleed widget and pad the contents instead.
    var padding: CGFloat
    var settings: [WidgetSettingSpec]
    var permissions: WidgetPermissions
}

enum ScriptError: LocalizedError {
    case evaluation(String)
    case missingWidgetCall
    case missingRender
    case render(String)
    case badNode
    case timedOut(TimeInterval)
    case noWatchdog
    case mixedPermissions

    var errorDescription: String? {
        switch self {
        case .evaluation(let message): message
        case .missingWidgetCall: "Script never called widget({ ... })"
        case .missingRender: "Widget has no render function"
        case .render(let message): message
        case .badNode: "render() did not return a widget node"
        case .timedOut(let budget): "Stopped after \(Int(budget * 1000))ms — script never returned"
        case .noWatchdog: "Cannot run scripts safely: JavaScript watchdog unavailable"
        case .mixedPermissions: "Widgets cannot mix network with media or battery"
        }
    }
}

/// Stops a script that will not stop itself.
///
/// The whole premise here is user-authored JavaScript, and JavaScript cannot
/// be interrupted from the outside once it is running. A `while (true)` in any
/// widget would wedge the main thread and take the panel, the menu bar and the
/// media island down with it — a structural hole in a scripting platform, not
/// a bug in a particular script.
///
/// JavaScriptCore has a watchdog built for exactly this. It is a real export,
/// but it is declared in a private header, so the symbol is resolved at
/// runtime and its absence is treated as a hard refusal to run scripts rather
/// than as permission to run them unguarded.
///
/// The watchdog polls at loop back-edges and function calls, which is what
/// catches a runaway loop. It cannot interrupt a single long-running host
/// call, but every host call here returns a small value immediately.
private enum ScriptWatchdog {
    typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool

    private typealias SetLimit = @convention(c) (
        JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?
    ) -> Void
    private typealias ClearLimit = @convention(c) (JSContextGroupRef?) -> Void

    /// `RTLD_DEFAULT`. JavaScriptCore is linked already, so there is nothing
    /// to open — this only asks the loader for a symbol it did not publish.
    private static var anyLoadedImage: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    private static let setLimit: SetLimit? = dlsym(
        anyLoadedImage, "JSContextGroupSetExecutionTimeLimit"
    ).map { unsafeBitCast($0, to: SetLimit.self) }

    private static let clearLimit: ClearLimit? = dlsym(
        anyLoadedImage, "JSContextGroupClearExecutionTimeLimit"
    ).map { unsafeBitCast($0, to: ClearLimit.self) }

    static var isAvailable: Bool { setLimit != nil }

    /// `owner` comes back untouched as the callback's second argument, which is
    /// the only way a C callback can find its way home.
    static func arm(_ context: JSContext, seconds: TimeInterval, owner: UnsafeMutableRawPointer) {
        setLimit?(
            JSContextGetGroup(context.jsGlobalContextRef),
            seconds,
            scriptExceededBudget,
            owner
        )
    }

    static func disarm(_ context: JSContext) {
        clearLimit?(JSContextGetGroup(context.jsGlobalContextRef))
    }
}

/// Runs on the thread executing the script, which is the thread that armed it.
/// Returning true is what actually terminates the script.
private let scriptExceededBudget: ScriptWatchdog.ShouldTerminate = { _, owner in
    guard let owner else { return true }
    Unmanaged<ScriptRuntime>.fromOpaque(owner).takeUnretainedValue().didExceedBudget = true
    return true
}

/// One JavaScript context per script, so a script cannot clobber its neighbours'
/// globals. Not thread safe by design — everything runs on the main actor.
final class ScriptRuntime {
    /// Wall-clock ceiling for one render. Building a small node tree costs
    /// well under a millisecond, so this is generous by orders of magnitude
    /// while keeping a runaway script to a dropped frame instead of a hang.
    static let renderBudget: TimeInterval = 0.1

    /// Loading runs a script's top level, which may legitimately do more setup
    /// work than a render ever does.
    static let loadBudget: TimeInterval = 0.5

    /// Supplies `notch.media()`. Injected rather than imported so the runtime
    /// stays independent of how now-playing is sourced.
    var mediaProvider: (() -> [String: Any]?)?

    /// Persistent key-value, files, fetch and user-facing settings. Same
    /// injection story as media: the runtime does not own the disk.
    var storageGet: ((String) -> Any?)?
    var storageSet: ((String, Any?) -> Void)?
    var fileRead: ((String) -> String?)?
    var fileWrite: ((String, String) -> String?)?
    var fetchHandler: ((String, TimeInterval) -> [String: Any])?
    var settingGet: ((String) -> Any?)?

    /// How long the last completed entry into JavaScript took.
    private(set) var lastDuration: TimeInterval = 0

    /// Declared on `widget({...})`. Host calls use `permissions`, which is
    /// this set intersected with whatever the user has granted.
    private(set) var declaredPermissions = WidgetPermissions()

    /// Set on a successful `load`. Host calls check this rather than trusting
    /// the script to only use what it asked for.
    private(set) var permissions = WidgetPermissions()

    /// Written by the watchdog callback, hence not private.
    fileprivate var didExceedBudget = false

    private let context: JSContext
    private var definition: JSValue?
    private var pendingException: String?
    private var hasWarnedSlow = false

    init() {
        setenv("JSC_useJIT", "0", 1)
        setenv("JSC_useDFGJIT", "0", 1)
        setenv("JSC_useFTLJIT", "0", 1)
        context = JSContext()!
        context.exceptionHandler = { [weak self] _, exception in
            self?.pendingException = exception?.toString() ?? "Unknown JavaScript error"
        }
        installHostAPI()
        // The prelude is ours, but it still runs through the budget so a
        // mistake in it cannot hang the app either.
        try? enterJavaScript(budget: Self.loadBudget) {
            context.evaluateScript(Self.prelude)
        }
    }

    deinit {
        ScriptWatchdog.disarm(context)
    }

    // MARK: - Running

    /// Every entry into JavaScript goes through here. Nothing else may call
    /// `evaluateScript` or `JSValue.call` directly — an unguarded entry is
    /// exactly the hole this closes.
    private func enterJavaScript(budget: TimeInterval, _ body: () -> Void) throws {
        guard ScriptWatchdog.isAvailable else { throw ScriptError.noWatchdog }

        didExceedBudget = false
        ScriptWatchdog.arm(
            context,
            seconds: budget,
            owner: Unmanaged.passUnretained(self).toOpaque()
        )
        defer { ScriptWatchdog.disarm(context) }

        let started = ContinuousClock.now
        body()

        let elapsed = (ContinuousClock.now - started).components
        lastDuration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18

        // Checked before `pendingException`: termination also raises one, and
        // "JavaScript execution terminated" is a far worse thing to show the
        // user than the budget that was actually blown.
        if didExceedBudget { throw ScriptError.timedOut(budget) }

        warnIfSlow()
    }

    /// A script that is merely slow is not killed — it is the user's script
    /// and it still works — but it janks every animation on screen, so it is
    /// worth saying so once.
    private func warnIfSlow() {
        let threshold = Self.renderBudget / 4
        guard lastDuration > threshold, !hasWarnedSlow else { return }
        hasWarnedSlow = true
        Logger.scripts.notice(
            "script took \(self.lastDuration * 1000, format: .fixed(precision: 1))ms; this will stutter the panel"
        )
    }

    // MARK: - Loading

    func load(source: String) throws -> ScriptDefinition {
        definition = nil
        pendingException = nil
        permissions = WidgetPermissions()
        declaredPermissions = WidgetPermissions()

        try enterJavaScript(budget: Self.loadBudget) {
            context.evaluateScript(source)
        }

        if let pendingException { throw ScriptError.evaluation(pendingException) }
        guard let definition, !definition.isUndefined else { throw ScriptError.missingWidgetCall }

        let permissions = WidgetPermissions.parse(
            definition.property("permissions")?.toDictionary()
        )
        if permissions.mixesNetworkWithSecrets { throw ScriptError.mixedPermissions }
        declaredPermissions = permissions
        self.permissions = permissions

        return ScriptDefinition(
            name: definition.property("name")?.toString() ?? "Widget",
            span: Self.span(from: definition.property("span")),
            refresh: definition.property("refresh")?.toDouble() ?? 0,
            padding: definition.property("padding").map { CGFloat($0.toDouble()) } ?? 8,
            settings: WidgetSettingSpec.parse(definition.property("settings")?.toDictionary()),
            permissions: permissions
        )
    }

    func render(timestamp: TimeInterval, span: WidgetSpan = .small) throws -> WidgetNode {
        guard let render = definition?.property("render") else { throw ScriptError.missingRender }

        pendingException = nil
        var result: JSValue?
        try enterJavaScript(budget: Self.renderBudget) {
            // `span` is the cell the board actually gave this tile, which is
            // not always what the script declared — the user can resize it.
            result = render.call(withArguments: [[
                "timestamp": timestamp,
                "span": [span.columns, span.rows],
                "columns": span.columns,
                "rows": span.rows
            ]])
        }

        if let pendingException { throw ScriptError.render(pendingException) }

        guard let node = WidgetNode.parse(result?.toDictionary()) else { throw ScriptError.badNode }
        return node
    }

    /// Host calls check `permissions`. Tests pass nil and keep the declared set;
    /// the panel intersects with what the user has granted.
    func applyGrants(_ granted: WidgetPermissions?) {
        permissions = declaredPermissions.intersection(granted ?? declaredPermissions)
    }

    /// Optional. `null` / a missing function means this widget is not claiming
    /// the collapsed wings this frame. A bad tree is dropped rather than
    /// failing the board render — island is extra, not the tile.
    func island(context: IslandScriptContext) throws -> IslandClaim? {
        guard let island = definition?.property("island") else { return nil }

        pendingException = nil
        var result: JSValue?
        try enterJavaScript(budget: Self.renderBudget) {
            var payload = context.scriptValue
            payload["timestamp"] = Date().timeIntervalSince1970
            result = island.call(withArguments: [payload])
        }

        if let pendingException { throw ScriptError.render(pendingException) }
        guard let result, !result.isUndefined, !result.isNull else { return nil }
        guard var claim = IslandClaim.parse(result.toDictionary()) else { return nil }
        // Playback is a media capability. A network widget cannot claim the
        // wings as a play/pause button any more than it can read the session.
        if !permissions.media { claim.action = nil }
        return claim
    }

    var definesIsland: Bool { definition?.property("island") != nil }

    func dispatchAction(_ name: String) {
        guard let handler = definition?.property("onAction") else { return }
        pendingException = nil
        try? enterJavaScript(budget: Self.renderBudget) {
            handler.call(withArguments: [name])
        }
    }

    // MARK: - Host API

    private func installHostAPI() {
        let register: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.definition = value
        }
        context.setObject(register, forKeyedSubscript: "widget" as NSString)

        let log: @convention(block) (String) -> Void = { message in
            Logger.scripts.log("\(message, privacy: .private)")
        }
        let console = JSValue(newObjectIn: context)
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 }
        let battery: @convention(block) () -> [String: Any]? = { [weak self] in
            guard self?.permissions.battery == true else { return nil }
            return PowerSource.current()?.scriptValue
        }
        let media: @convention(block) () -> [String: Any]? = { [weak self] in
            guard self?.permissions.media == true else { return nil }
            return self?.mediaProvider?()
        }

        let store: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            self?.storageSet?(key, Self.jsonValue(from: value))
        }
        let load: @convention(block) (String) -> Any? = { [weak self] key in
            self?.storageGet?(key)
        }
        let read: @convention(block) (String) -> String? = { [weak self] name in
            self?.fileRead?(name)
        }
        let write: @convention(block) (String, String) -> String? = { [weak self] name, contents in
            self?.fileWrite?(name, contents)
        }
        let fetchBlock: @convention(block) (String, JSValue) -> [String: Any] = { [weak self] url, options in
            guard self?.permissions.network == true else {
                return ["ok": false, "error": "This widget has no network permission"]
            }
            let ttl = options.property("ttl")?.toDouble() ?? 300
            return self?.fetchHandler?(url, ttl) ?? ["ok": false, "error": "Fetch is unavailable"]
        }
        let setting: @convention(block) (String) -> Any? = { [weak self] key in
            self?.settingGet?(key)
        }

        let host = JSValue(newObjectIn: context)
        host?.setObject(now, forKeyedSubscript: "now" as NSString)
        host?.setObject(battery, forKeyedSubscript: "battery" as NSString)
        host?.setObject(media, forKeyedSubscript: "media" as NSString)
        host?.setObject(store, forKeyedSubscript: "store" as NSString)
        host?.setObject(load, forKeyedSubscript: "load" as NSString)
        host?.setObject(read, forKeyedSubscript: "read" as NSString)
        host?.setObject(write, forKeyedSubscript: "write" as NSString)
        host?.setObject(fetchBlock, forKeyedSubscript: "fetch" as NSString)
        host?.setObject(setting, forKeyedSubscript: "setting" as NSString)
        context.setObject(host, forKeyedSubscript: "notch" as NSString)
    }

    /// JSValue → JSON-ish, or nil. Anything that cannot round-trip through
    /// `JSONSerialization` is dropped rather than crashing the store.
    private static func jsonValue(from value: JSValue) -> Any? {
        if value.isNull || value.isUndefined { return nil }
        if value.isString { return value.toString() }
        if value.isBoolean { return value.toBool() }
        if value.isNumber { return value.toNumber() }
        if value.isArray { return value.toArray() }
        return value.toDictionary()
    }

    /// Accepts either `span: [2, 1]` or `span: { columns: 2, rows: 1 }`.
    private static func span(from value: JSValue?) -> WidgetSpan {
        guard let value else { return .small }

        if let pair = value.toArray() as? [Int], pair.count == 2 {
            return WidgetSpan(columns: pair[0], rows: pair[1])
        }
        if let columns = value.property("columns")?.toNumber()?.intValue,
           let rows = value.property("rows")?.toNumber()?.intValue {
            return WidgetSpan(columns: columns, rows: rows)
        }
        return .small
    }

    /// Builders live in JavaScript rather than in the bridge, which keeps the
    /// Swift surface to just `widget`, `console` and `notch`.
    private static let prelude = #"""
    (function (global) {
      function node(type, props) {
        var result = { type: type };
        if (props) {
          for (var key in props) {
            if (Object.prototype.hasOwnProperty.call(props, key)) result[key] = props[key];
          }
        }
        return result;
      }

      global.text = function (value, options) {
        return node("text", Object.assign({ value: String(value) }, options || {}));
      };
      global.symbol = function (name, options) {
        return node("symbol", Object.assign({ name: name }, options || {}));
      };
      global.progress = function (value, options) {
        return node("progress", Object.assign({ value: value }, options || {}));
      };
      global.spacer = function (length) {
        return node("spacer", length === undefined ? {} : { length: length });
      };
      global.vstack = function (children, options) {
        return node("stack", Object.assign({ axis: "vertical", children: children || [] }, options || {}));
      };
      global.hstack = function (children, options) {
        return node("stack", Object.assign({ axis: "horizontal", children: children || [] }, options || {}));
      };
      global.zstack = function (children, options) {
        return node("stack", Object.assign({ axis: "layered", children: children || [] }, options || {}));
      };
      global.artwork = function (options) {
        return node("artwork", options || {});
      };
      global.button = function (action, child, options) {
        return node("button", Object.assign({ action: action, child: child }, options || {}));
      };
      global.list = function (items, options) {
        return node("list", Object.assign({ items: items || [] }, options || {}));
      };
      global.chart = function (values, options) {
        return node("chart", Object.assign({ values: values || [] }, options || {}));
      };
      global.equaliser = function (options) {
        return node("equaliser", options || {});
      };

      var nativeFetch = global.notch && global.notch.fetch;
      if (nativeFetch) {
        global.notch.fetch = function (url, options) {
          return nativeFetch(url, options || {});
        };
      }
    })(this);
    """#
}

private extension JSValue {
    /// Property lookup that treats `undefined` and `null` as absent.
    func property(_ key: String) -> JSValue? {
        guard let value = objectForKeyedSubscript(key), !value.isUndefined, !value.isNull else {
            return nil
        }
        return value
    }
}

extension Logger {
    static let scripts = Logger(subsystem: "me.hwll.fringe", category: "scripts")
}
