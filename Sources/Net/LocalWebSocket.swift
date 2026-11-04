import Foundation

/// A WebSocket to a TV on the LAN (self-signed TLS allowed), delivering text frames on the main actor.
@MainActor
final class LocalWebSocket {
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let task: URLSessionWebSocketTask
    private let observer: Observer
    private var closed = false
    private(set) var isReady = false

    init(url: URL) {
        observer = Observer()
        let session = URLSession(configuration: .ephemeral, delegate: observer, delegateQueue: .main)
        task = session.webSocketTask(with: url)
        observer.owner = self
    }

    func start() {
        task.resume()
        receive()
    }

    func send(_ text: String) {
        task.send(.string(text)) { _ in }
    }

    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(String(decoding: data, as: UTF8.self))
    }

    func sendAndWait(_ text: String) async {
        guard isReady, !closed, !Task.isCancelled else { return }
        try? await task.send(.string(text))
    }

    func sendAndWait(json: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        await sendAndWait(String(decoding: data, as: UTF8.self))
    }

    func close() {
        guard !closed else { return }
        closed = true
        isReady = false
        onClose = nil
        task.cancel(with: .goingAway, reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case .success(.string(let text)):
                    self.onText?(text)
                    self.receive()
                case .success(.data(let data)):
                    self.onText?(String(decoding: data, as: UTF8.self))
                    self.receive()
                case .success:
                    self.receive()
                case .failure(let error):
                    self.finish(error)
                }
            }
        }
    }

    fileprivate func opened() { isReady = true; onOpen?() }

    fileprivate func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        isReady = false
        onClose?(error)
    }

    private final class Observer: LocalTrustDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
        weak var owner: LocalWebSocket?

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            MainActor.assumeIsolated { owner?.opened() }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            MainActor.assumeIsolated { owner?.finish(nil) }
            session.invalidateAndCancel()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            MainActor.assumeIsolated { owner?.finish(error) }
            session.invalidateAndCancel()
        }
    }
}

enum JSON {
    static func parse(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
