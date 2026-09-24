import Foundation
import Network

/// HTTPS fetch for scripts, with a cache so `render()` never waits.
///
/// JavaScriptCore host functions are synchronous and run on the main thread
/// inside a 100ms budget. A real `await fetch` would either blow that budget
/// or hang the panel. So a script *asks* for a URL and gets back whatever is
/// already known: a pending marker, a cached body, or an error. The actual
/// request runs off-thread and the widget is asked to render again when it
/// lands.
///
/// The destination is the public internet, not the machine and not the LAN.
/// A gallery script that can hit `192.168.x` or `*.local` is a scanner;
/// https-only is not enough. Hostnames are allowed as strings and checked
/// again after DNS, because a name can rebind to a private address. Redirects
/// go through the same gate, or `https://example.com` → `https://192.168.1.1`
/// would be a LAN fetch. The connected peer is checked again in session
/// metrics, because URLSession does its own lookup after ours.
@MainActor
final class WidgetNetwork {
    nonisolated static let maxBytes = 512 * 1024
    nonisolated static let timeout: TimeInterval = 12
    nonisolated static let defaultTTL: TimeInterval = 300
    nonisolated static let maxTTL: TimeInterval = 86_400
    nonisolated static let maxCacheEntries = 24
    nonisolated static let maxJSONDepth = 8

    var onUpdate: (() -> Void)?

    private var cache: [String: Entry] = [:]
    private var inflight: Set<String> = []

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        return URLSession(
            configuration: config,
            delegate: PublicInternetGate.shared,
            delegateQueue: nil
        )
    }()

    private struct Entry {
        var fetchedAt: Date
        var ttl: TimeInterval
        var payload: [String: Any]

        var isFresh: Bool { Date().timeIntervalSince(fetchedAt) < ttl }
    }

    func lookup(_ raw: String, ttl: TimeInterval) -> [String: Any] {
        guard let url = Self.allowedURL(raw) else {
            return ["ok": false, "error": "Only public https URLs are allowed"]
        }

        let ttl = Self.clampedTTL(ttl)
        let key = url.absoluteString
        if let entry = cache[key], entry.isFresh {
            return entry.payload
        }
        if let entry = cache[key] {
            start(url, ttl: ttl, key: key)
            return entry.payload
        }

        start(url, ttl: ttl, key: key)
        return ["pending": true]
    }

    func invalidate() {
        cache.removeAll()
        onUpdate?()
    }

    nonisolated static func clampedTTL(_ ttl: TimeInterval) -> TimeInterval {
        guard ttl.isFinite else { return defaultTTL }
        return min(max(ttl, 0), maxTTL)
    }

    /// https, a host, no userinfo, and that host is not this machine or the LAN.
    nonisolated static func allowedURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil,
              url.password == nil,
              isPublicInternetHost(host)
        else { return nil }
        return url
    }

    /// Loopback, link-local, RFC1918, ULA, Bonjour, localhost. A hostname
    /// that is none of those still has to resolve publicly at connect time.
    nonisolated static func isPublicInternetHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "local"
            || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return false
        }
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: "%").first.map(String.init) ?? host
        if let ipv4 = IPv4Address(address) { return isPublicIPv4(ipv4, spelled: address) }
        if let ipv6 = IPv6Address(address) { return isPublicIPv6(ipv6) }
        return true
    }

    /// Fail closed if any record is private. Split-horizon and nip.io-style
    /// rebinding are the gallery attack; matching the URL string is not.
    nonisolated static func resolvesToPublicInternet(_ host: String) -> Bool {
        guard isPublicInternetHost(host) else { return false }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { getaddrinfo($0, nil, &hints, &result) }
        guard status == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var sawAddress = false
        while let pointer = current {
            sawAddress = true
            let info = pointer.pointee
            if let addr = info.ai_addr, !sockaddrIsPublic(addr, length: info.ai_addrlen) {
                return false
            }
            current = info.ai_next
        }
        return sawAddress
    }

    private func start(_ url: URL, ttl: TimeInterval, key: String) {
        guard !inflight.contains(key) else { return }
        inflight.insert(key)

        Task { [weak self] in
            let payload = await Self.download(url)
            guard let self else { return }
            self.inflight.remove(key)
            self.store(key, ttl: ttl, payload: payload)
            self.onUpdate?()
        }
    }

    private func store(_ key: String, ttl: TimeInterval, payload: [String: Any]) {
        cache[key] = Entry(fetchedAt: .now, ttl: ttl, payload: payload)
        guard cache.count > Self.maxCacheEntries else { return }
        let extra = cache.count - Self.maxCacheEntries
        let oldest = cache.sorted { $0.value.fetchedAt < $1.value.fetchedAt }.prefix(extra)
        for item in oldest {
            cache.removeValue(forKey: item.key)
        }
    }

    private static func download(_ url: URL) async -> [String: Any] {
        let host = url.host ?? ""
        let isPublic = await Task.detached(priority: .utility) {
            resolvesToPublicInternet(host)
        }.value
        guard isPublic else {
            return ["ok": false, "error": "Only public https URLs are allowed"]
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Fringe/0.1 (widget)", forHTTPHeaderField: "User-Agent")

        do {
            let result = try await perform(request)
            let data = result.data
            let response = result.response
            let rejected = result.rejected
            if rejected {
                return ["ok": false, "error": "Only public https URLs are allowed"]
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if data.count > maxBytes {
                return ["ok": false, "error": "Response too large", "code": code]
            }

            var payload: [String: Any] = ["ok": code >= 200 && code < 400, "code": code]
            if let object = try? JSONSerialization.jsonObject(with: data),
               let json = cappedJSON(object) {
                payload["json"] = json
            } else if let text = String(data: data, encoding: .utf8) {
                payload["text"] = text
            }
            if code >= 400 {
                payload["ok"] = false
                payload["error"] = "HTTP \(code)"
            }
            return payload
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private struct FetchBody {
        var data: Data
        var response: URLResponse
        var rejected: Bool
    }

    private static func perform(_ request: URLRequest) async throws -> FetchBody {
        try await withCheckedThrowingContinuation { continuation in
            let box = TaskBox()
            let task = session.dataTask(with: request) { data, response, error in
                let rejected = box.task.map { PublicInternetGate.shared.consumeRejection($0) } ?? false
                if rejected {
                    continuation.resume(returning: FetchBody(data: Data(), response: URLResponse(), rejected: true))
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: FetchBody(data: data, response: response, rejected: false))
            }
            box.task = task
            task.resume()
        }
    }

    /// Unusual spellings (`127.1`, `2130706433`) parse as IPv4 in some
    /// stacks; if it is not four decimal octets, it is not going out.
    private nonisolated static func isPublicIPv4(_ address: IPv4Address, spelled: String) -> Bool {
        let octets = spelled.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, address.isLoopback == false,
              !address.isLinkLocal, !address.isMulticast
        else { return false }
        switch octets[0] {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(octets[1]): return false
        case 172 where (16...31).contains(octets[1]): return false
        case 192 where octets[1] == 168: return false
        default: return true
        }
    }

    private nonisolated static func isPublicIPv4(bytes: some Collection<UInt8>) -> Bool {
        let octets = Array(bytes)
        guard octets.count == 4 else { return false }
        let spelled = octets.map(String.init).joined(separator: ".")
        guard let ipv4 = IPv4Address(spelled) else { return false }
        return isPublicIPv4(ipv4, spelled: spelled)
    }

    /// Also unwraps NAT64, 6to4, Teredo, and deprecated IPv4-compatible
    /// embeddings. `::ffff:` mapped addresses were the only ones caught before.
    private nonisolated static func isPublicIPv6(_ address: IPv6Address) -> Bool {
        if address.isLoopback || address.isLinkLocal || address.isMulticast { return false }
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 16 else { return false }
        if bytes[0] == 0xfc || bytes[0] == 0xfd { return false }

        let mapped = bytes.prefix(10).allSatisfy { $0 == 0 }
            && bytes[10] == 0xff && bytes[11] == 0xff
        if mapped { return isPublicIPv4(bytes: bytes.suffix(4)) }

        let compatible = bytes.prefix(12).allSatisfy { $0 == 0 }
        if compatible { return isPublicIPv4(bytes: bytes.suffix(4)) }

        // 6to4: 2002:V4ADDR::/48
        if bytes[0] == 0x20 && bytes[1] == 0x02 {
            return isPublicIPv4(bytes: bytes[2..<6])
        }

        // NAT64 well-known prefix 64:ff9b::/96, and 64:ff9b:1::/48.
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b {
            return isPublicIPv4(bytes: bytes.suffix(4))
        }

        // Teredo: 2001:0000::/32, client IPv4 is the last 32 bits inverted.
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x00 {
            return isPublicIPv4(bytes: bytes.suffix(4).map { $0 ^ 0xff })
        }

        return true
    }

    private nonisolated static func sockaddrIsPublic(
        _ addr: UnsafePointer<sockaddr>,
        length: socklen_t
    ) -> Bool {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        else { return false }
        let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let numeric = String(bytes: bytes, encoding: .utf8) else { return false }
        return isPublicInternetHost(numeric)
    }

    nonisolated static func cappedJSON(_ value: Any, depth: Int = 0) -> Any? {
        guard depth <= maxJSONDepth else { return nil }
        switch value {
        case is NSNull, is String, is NSNumber: return value
        case let array as [Any]:
            return array.prefix(128).compactMap { cappedJSON($0, depth: depth + 1) }
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            for (key, nested) in object.prefix(64) {
                if let capped = cappedJSON(nested, depth: depth + 1) {
                    result[key] = capped
                }
            }
            return result
        default:
            return nil
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    var task: URLSessionDataTask?
}

/// Same gate as `allowedURL`, applied to every hop. URLSession follows
/// redirects before the caller sees them, so the string check on the
/// original URL is otherwise a one-shot. Metrics catch a rebind between
/// our `getaddrinfo` and the socket URLSession actually opened.
private final class PublicInternetGate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = PublicInternetGate()

    private let lock = NSLock()
    private var rejected: Set<Int> = []

    func consumeRejection(_ task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected.remove(task.taskIdentifier) != nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              WidgetNetwork.allowedURL(url.absoluteString) != nil,
              let host = url.host,
              WidgetNetwork.resolvesToPublicInternet(host)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        for item in metrics.transactionMetrics {
            guard let remote = item.remoteAddress, !remote.isEmpty else { continue }
            if WidgetNetwork.isPublicInternetHost(remote) { continue }
            lock.lock()
            rejected.insert(task.taskIdentifier)
            lock.unlock()
            task.cancel()
            return
        }
    }
}
