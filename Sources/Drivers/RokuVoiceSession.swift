import Foundation

/// Manages a Roku ECP WebSocket session for sending voice audio to the TV.
/// Protocol: ws://IP:8060/ecp-session with subprotocol "ecp-2"
@MainActor
final class RokuVoiceSession {
    private var webSocket: URLSessionWebSocketTask?
    private let host: String
    private var isActive = false
    
    init(host: String) {
        self.host = host
    }
    
    /// Open the ECP session WebSocket connection.
    func open() async throws {
        guard !isActive else { return }
        
        let url = URL(string: "ws://\(host):8060/ecp-session")!
        var request = URLRequest(url: url)
        request.setValue("ecp-2", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        
        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()
        
        isActive = true
        startReceiving()
    }
    
    /// Send voice audio data. Data should be 16-bit LE PCM.
    func sendVoiceData(_ data: Data) async throws {
        guard isActive, let webSocket else { return }
        
        var packet = Data()
        packet.append(contentsOf: [0x01])
        packet.append(data)
        
        try await webSocket.send(.data(packet))
    }
    
    /// Close the WebSocket session.
    func close() {
        guard isActive else { return }
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isActive = false
    }
    
    private func startReceiving() {
        guard isActive, let webSocket else { return }
        
        Task { @MainActor in
            do {
                let message = try await webSocket.receive()
                switch message {
                case .data, .string:
                    break
                @unknown default:
                    break
                }
                if self.isActive {
                    self.startReceiving()
                }
            } catch {
                self.isActive = false
            }
        }
    }
    
    deinit {
        if isActive {
            webSocket?.cancel(with: .goingAway, reason: nil)
        }
    }
}
