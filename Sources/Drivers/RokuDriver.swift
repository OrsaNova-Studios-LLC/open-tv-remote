import Foundation

/// Roku External Control Protocol: plain HTTP on port 8060, no pairing.
@MainActor
final class RokuDriver: TVDriver {
    private(set) var device: TVDevice
    weak var delegate: TVDriverDelegate?
    private(set) var state: ConnectionState = .idle {
        didSet { if state != oldValue { delegate?.driver(self, didChangeState: state) } }
    }

    private var base: URL { URL(string: "http://\(device.host):8060")! }
    /// Keypresses must arrive in order, so they go through one serial chain.
    private var queue: Task<Void, Never>?
    private var generation = 0
    
    private var voiceSession: RokuVoiceSession?
    private var audioCapture: AudioCapture?

    init(device: TVDevice) {
        self.device = device
    }

    func connect() {
        generation += 1
        state = .connecting
        let token = generation
        Task {
            let data = await LocalHTTP.get(base.appending(path: "query/device-info"), timeout: 4)
            guard token == generation else { return }
            guard let data else {
                state = .failed("Couldn't reach the Roku. Is it on and on the same Wi-Fi?")
                return
            }
            if let name = XMLText.first("user-device-name", in: data) ?? XMLText.first("friendly-device-name", in: data),
               name != device.name {
                device.name = name
                device.model = XMLText.first("model-name", in: data)
                delegate?.driver(self, didUpdateDevice: device)
            }
            state = .connected
        }
    }

    func pair() { connect() }
    func submitPairingCode(_ code: String) {}

    func disconnect() {
        generation += 1
        queue?.cancel()
        stopVoice()
        state = .idle
    }

    func supports(_ key: RemoteKey) -> Bool { Self.keyName(key) != nil }

    func send(_ key: RemoteKey) {
        guard let name = Self.keyName(key) else { return }
        enqueue("keypress/\(name)")
    }

    func sendInteractive(_ key: RemoteKey, request: RemoteInputRequest) async {
        guard state == .connected, !request.isCancelled, !Task.isCancelled,
              let name = Self.keyName(key) else { return }
        let operation = enqueue("keypress/" + name, request: request)
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    func sendText(_ text: String) {
        for scalar in text.unicodeScalars {
            let encoded = String(scalar).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            enqueue("keypress/Lit_\(encoded)")
        }
    }

    func launch(_ app: TVApp) {
        enqueue("launch/\(app.launchID)")
    }

    func installedApps() async -> [TVApp]? {
        guard let data = await LocalHTTP.get(base.appending(path: "query/apps")) else { return nil }
        return RokuAppsParser.parse(data).map {
            TVApp(name: $0.name, launchID: $0.id, iconURL: base.appending(path: "query/icon/\($0.id)"))
        }
    }
    
    var supportsVoice: Bool { true }
    
    func startVoice() async throws {
        guard state == .connected else { return }
        guard audioCapture == nil else { return }
        
        let granted = await AudioCapture.requestPermission()
        guard granted else {
            throw AudioCaptureError.permissionDenied
        }
        
        let session = RokuVoiceSession(host: device.host)
        try await session.open()
        voiceSession = session
        
        let capture = AudioCapture(sampleRate: 16000)
        audioCapture = capture
        
        try capture.start { [weak self, weak session] data in
            guard let session else { return }
            Task {
                try? await session.sendVoiceData(data)
            }
        }
    }
    
    func stopVoice() {
        audioCapture?.stop()
        audioCapture = nil
        voiceSession?.close()
        voiceSession = nil
    }

    @discardableResult
    private func enqueue(_ path: String, request: RemoteInputRequest? = nil) -> Task<Void, Never> {
        let previous = queue
        let token = generation
        // Percent-encoded paths must not be re-encoded by appending(path:).
        let url = URL(string: base.absoluteString + "/" + path)!
        let operation = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, token == self.generation else { return }
            if let request {
                guard !request.isCancelled, self.state == .connected else { return }
            }
            let status = await LocalHTTP.post(url, timeout: request == nil ? 3 : 2)
            guard !Task.isCancelled, token == self.generation else { return }
            switch status {
            case 200?, 202?, 204?:
                guard request?.isCancelled != true else { return }
                if self.state != .connected { self.state = .connected }
            case 403?:
                self.state = .failed("Your Roku is blocking remote apps. On the Roku, go to Settings → System → Advanced system settings → Control by mobile apps and set Network access to Default or Permissive.")
            case nil:
                self.state = .failed("Couldn't reach the Roku.")
            default:
                break
            }
        }
        queue = operation
        return operation
    }

    private static func keyName(_ key: RemoteKey) -> String? {
        switch key {
        case .power: "Power"
        case .powerOff: nil
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .select: "Select"
        case .back: "Back"
        case .home, .exit: "Home"
        case .menu, .info: "Info"
        case .input: "InputTuner"
        case .search: "Search"
        case .volumeUp: "VolumeUp"
        case .volumeDown: "VolumeDown"
        case .mute: "VolumeMute"
        case .channelUp: "ChannelUp"
        case .channelDown: "ChannelDown"
        case .playPause: "Play"
        case .rewind: "Rev"
        case .fastForward: "Fwd"
        case .backspace: "Backspace"
        case .enter: "Enter"
        case .digit(let n): "Lit_\(n)"
        }
    }
}

/// Parses `<apps><app id="12" type="appl" version="…">Netflix</app>…</apps>`.
final class RokuAppsParser: NSObject, XMLParserDelegate {
    private var apps: [(id: String, name: String)] = []
    private var currentID: String?
    private var text = ""

    static func parse(_ data: Data) -> [(id: String, name: String)] {
        let p = RokuAppsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.apps
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        guard name == "app" else { return }
        // Skip system entries like the TV tuner and HDMI inputs.
        currentID = attributes["type"] == "appl" ? attributes["id"] : nil
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "app", let id = currentID {
            apps.append((id, text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        currentID = nil
    }
}
