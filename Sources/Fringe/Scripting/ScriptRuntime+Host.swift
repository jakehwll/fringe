import Foundation
import JavaScriptCore
import OSLog

extension ScriptRuntime {
    // MARK: - Host API

    func installHostAPI() {
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

        let host = JSValue(newObjectIn: context)
        host?.setObject(now, forKeyedSubscript: "now" as NSString)
        host?.setObject(battery, forKeyedSubscript: "battery" as NSString)
        host?.setObject(media, forKeyedSubscript: "media" as NSString)
        attachStorage(to: host)
        context.setObject(host, forKeyedSubscript: "notch" as NSString)
    }

    private func attachStorage(to host: JSValue?) {
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
        host?.setObject(store, forKeyedSubscript: "store" as NSString)
        host?.setObject(load, forKeyedSubscript: "load" as NSString)
        host?.setObject(read, forKeyedSubscript: "read" as NSString)
        host?.setObject(write, forKeyedSubscript: "write" as NSString)
        host?.setObject(fetchBlock, forKeyedSubscript: "fetch" as NSString)
        host?.setObject(setting, forKeyedSubscript: "setting" as NSString)
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

    /// Builders live in JavaScript rather than in the bridge, which keeps the
    /// Swift surface to just `widget`, `console` and `notch`.
    static let prelude = #"""
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
