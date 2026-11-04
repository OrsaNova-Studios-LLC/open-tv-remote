// Host-only substitutes for the networking types. These never open sockets.
import Foundation

@MainActor
final class LocalWebSocket {
    static var instances: [LocalWebSocket] = []
    static var delayedOpenPaths: Set<String> = []
    let url: URL
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClose: ((Error?) -> Void)?
    private(set) var isReady = false
    private(set) var sent: [String] = []

    init(url: URL) { self.url = url; Self.instances.append(self) }
    func start() {
        if !Self.delayedOpenPaths.contains(url.path) { completeHandshake() }
    }
    func completeHandshake() { isReady = true; onOpen?() }
    func send(_ text: String) { sent.append(text) }
    func send(json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        send(String(decoding: data, as: UTF8.self))
    }
    func sendAndWait(_ text: String) async {
        if isReady { sent.append(text) }
    }
    func close() { isReady = false; onClose = nil }
    func peerClosed() { isReady = false; onClose?(nil) }
}

@MainActor
enum LocalHTTP {
    static var started: [String] = []
    static var completions: [String: CheckedContinuation<Int?, Never>] = [:]

    static func get(_ url: URL, timeout: TimeInterval = 3) async -> Data? {
        Data("<device-info/>".utf8)
    }
    static func post(_ url: URL, body: Data? = nil, timeout: TimeInterval = 3) async -> Int? {
        started.append(url.path)
        return await withCheckedContinuation { completions[url.path] = $0 }
    }
    static func complete(_ path: String, status: Int? = 200) {
        completions.removeValue(forKey: path)?.resume(returning: status)
    }
    static func reset() {
        for completion in completions.values { completion.resume(returning: nil) }
        completions = [:]
        started = []
    }
}

enum XMLText {
    static func first(_ tag: String, in data: Data) -> String? { nil }
}

enum JSON {
    static func parse(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
