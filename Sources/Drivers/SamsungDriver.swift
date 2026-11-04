import Foundation

/// Samsung Tizen TVs (2016+): WebSocket remote channel on port 8002.
/// The first connection shows an Allow/Deny prompt on the TV, after which it issues a token.
@MainActor
final class SamsungDriver: TVDriver {
    private(set) var device: TVDevice
    weak var delegate: TVDriverDelegate?
    private(set) var state: ConnectionState = .idle {
        didSet { if state != oldValue { delegate?.driver(self, didChangeState: state) } }
    }

    private var socket: LocalWebSocket?
    private var playing = true
    /// Keys pressed while (re)connecting, sent once the TV lets us in.
    private var pendingKeys: [String] = []
    private var pendingLaunch: TVApp?
    private var appsContinuation: CheckedContinuation<[TVApp]?, Never>?
    private var appsRequest = 0
    /// Reconnect attempts left after sending a Wake-on-LAN packet.
    private var wakeAttempts = 0

    init(device: TVDevice) {
        self.device = device
    }

    func connect() {
        guard device.token != nil else {
            state = .unpaired
            return
        }
        open(prompting: false)
    }

    func pair() { open(prompting: true) }
    func submitPairingCode(_ code: String) {}

    func disconnect() {
        socket?.close()
        socket = nil
        pendingKeys = []
        pendingLaunch = nil
        wakeAttempts = 0
        appsContinuation?.resume(returning: nil)
        appsContinuation = nil
        state = .idle
    }

    private func open(prompting: Bool) {
        socket?.close()
        let name = Data("Open Remote".utf8).base64EncodedString()
        var components = URLComponents(string: "wss://\(device.host):8002/api/v2/channels/samsung.remote.control")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if let token = device.token, !token.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "token", value: token))
        }
        let ws = LocalWebSocket(url: components.url!)
        state = prompting ? .pairing(.acceptOnTV) : .connecting
        ws.onText = { [weak self] in self?.handle($0) }
        ws.onClose = { [weak self] _ in
            guard let self else { return }
            self.socket = nil
            if self.wakeAttempts > 0 {
                self.wakeAttempts -= 1
                self.retryAfterWake()
                return
            }
            switch self.state {
            case .connected: self.state = .idle
            case .pairing: self.state = .failed("The TV didn't allow the connection.")
            default: self.state = .failed("Couldn't reach the TV. Is it on and on the same Wi-Fi?")
            }
        }
        socket = ws
        ws.start()
    }

    private func handle(_ text: String) {
        guard let json = JSON.parse(text), let event = json["event"] as? String else { return }
        let data = json["data"] as? [String: Any]
        switch event {
        case "ms.channel.connect":
            // Older models never issue tokens; remember that we've been allowed anyway.
            let token = data?["token"] as? String ?? device.token ?? ""
            if token != device.token {
                device.token = token
                delegate?.driver(self, didUpdateDevice: device)
            }
            wakeAttempts = 0
            state = .connected
            refreshInfo()
            let queued = pendingKeys
            pendingKeys = []
            queued.forEach(sendKey)
            if let app = pendingLaunch {
                pendingLaunch = nil
                launch(app)
            }
        case "ms.channel.unauthorized":
            device.token = nil
            delegate?.driver(self, didUpdateDevice: device)
            socket?.close()
            socket = nil
            state = .failed("The TV denied access. You can allow it under Settings → General → External Device Manager → Device Connection Manager.")
        case "ms.channel.timeOut":
            socket?.close()
            socket = nil
            state = .failed("Timed out waiting for you to allow access on the TV.")
        case "ed.installedApp.get":
            let list = (data?["data"] as? [[String: Any]]) ?? []
            let apps = list.compactMap { entry -> TVApp? in
                guard let id = entry["appId"] as? String, let name = entry["name"] as? String else { return nil }
                let type = entry["app_type"] as? Int
                return TVApp(name: name, launchID: id, extra: type == 4 ? "NATIVE_LAUNCH" : "DEEP_LINK")
            }
            appsContinuation?.resume(returning: apps)
            appsContinuation = nil
        default:
            break
        }
    }

    func supports(_ key: RemoteKey) -> Bool { Self.keyName(key) != nil }

    func send(_ key: RemoteKey) {
        if key == .powerOff {
            holdPower()
            return
        }
        guard var name = Self.keyName(key) else { return }
        if key == .playPause {
            name = playing ? "KEY_PAUSE" : "KEY_PLAY"
            playing.toggle()
        }
        guard state == .connected else {
            guard device.token != nil else { return }
            if key == .power, device.macAddress != nil {
                powerOnOrQueue()
                return
            }
            if pendingKeys.count < 10 { pendingKeys.append(name) }
            if socket == nil { open(prompting: false) }
            return
        }
        sendKey(name)
    }

    func sendInteractive(_ key: RemoteKey, request: RemoteInputRequest) async {
        guard state == .connected, !request.isCancelled, !Task.isCancelled, let name = Self.keyName(key), let socket else { return }
        await socket.sendAndWait(json: [
            "method": "ms.remote.control",
            "params": ["Cmd": "Click", "DataOfCmd": name, "Option": "false", "TypeOfRemote": "SendRemoteKey"],
        ])
    }

    private func sendKey(_ name: String) { sendKey(name, cmd: "Click") }

    private func sendKey(_ name: String, cmd: String) {
        socket?.send(json: [
            "method": "ms.remote.control",
            "params": ["Cmd": cmd, "DataOfCmd": name, "Option": "false", "TypeOfRemote": "SendRemoteKey"],
        ])
    }

    // MARK: Power

    /// Holding power for a few seconds turns the TV fully off. On The Frame a short press
    /// only toggles Art Mode.
    private func holdPower() {
        guard state == .connected else { return }
        sendKey("KEY_POWER", cmd: "Press")
        Task {
            try? await Task.sleep(for: .seconds(3))
            sendKey("KEY_POWER", cmd: "Release")
        }
    }

    /// Power pressed while we're not connected. If the TV is awake, our connection just dropped,
    /// so reconnect and send power as usual. If it's asleep, wake it with Wake-on-LAN instead;
    /// sending KEY_POWER after waking it would switch it straight back off.
    private func powerOnOrQueue() {
        Task {
            if await isAwake() {
                if pendingKeys.count < 10 { pendingKeys.append("KEY_POWER") }
                if socket == nil { open(prompting: false) }
            } else {
                wake()
            }
        }
    }

    private func wake() {
        guard let mac = device.macAddress else { return }
        WakeOnLAN.wake(mac: mac, host: device.host)
        socket?.close()
        socket = nil
        pendingKeys = []
        wakeAttempts = 5
        state = .connecting
        retryAfterWake()
    }

    /// The TV takes a few seconds to bring its network back up after a wake packet.
    private func retryAfterWake() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard wakeAttempts > 0, socket == nil, state == .connecting else { return }
            if let mac = device.macAddress { WakeOnLAN.wake(mac: mac, host: device.host) }
            open(prompting: false)
        }
    }

    private func deviceInfo(timeout: TimeInterval = 3) async -> [String: Any]? {
        guard let data = await LocalHTTP.get(URL(string: "http://\(device.host):8001/api/v2/")!, timeout: timeout),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["device"] as? [String: Any]
    }

    /// Older models don't report PowerState; if they answer at all, they're on.
    private func isAwake() async -> Bool {
        guard let info = await deviceInfo(timeout: 1.5) else { return false }
        let power = info["PowerState"] as? String
        return power == nil || power == "on"
    }

    /// Remember the TV's MAC so we can wake it later.
    private func refreshInfo() {
        Task {
            guard let info = await deviceInfo(),
                  let mac = info["wifiMac"] as? String, WakeOnLAN.macBytes(mac) != nil,
                  mac != device.macAddress else { return }
            device.macAddress = mac
            delegate?.driver(self, didUpdateDevice: device)
        }
    }

    /// Unverified whether SendInputString appends or replaces, and backspace maps to KEY_RETURN
    /// (Back), so the keyboard pad holds the text and sends it all on Return.
    var typesLive: Bool { false }

    func sendText(_ text: String) {
        guard state == .connected else { return }
        socket?.send(json: [
            "method": "ms.remote.control",
            "params": ["Cmd": Data(text.utf8).base64EncodedString(), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"],
        ])
    }

    func launch(_ app: TVApp) {
        guard state == .connected else {
            guard device.token != nil else { return }
            pendingLaunch = app
            if socket == nil { open(prompting: false) }
            return
        }
        socket?.send(json: [
            "method": "ms.channel.emit",
            "params": [
                "event": "ed.apps.launch",
                "to": "host",
                "data": ["appId": app.launchID, "action_type": app.extra ?? "DEEP_LINK"],
            ],
        ])
    }

    func installedApps() async -> [TVApp]? {
        guard state == .connected, let socket else { return nil }
        appsContinuation?.resume(returning: nil)
        appsRequest += 1
        let request = appsRequest
        return await withCheckedContinuation { continuation in
            appsContinuation = continuation
            socket.send(json: ["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]])
            Task {
                try? await Task.sleep(for: .seconds(4))
                // Only time out our own request, not a newer one that replaced it.
                guard request == appsRequest else { return }
                appsContinuation?.resume(returning: nil)
                appsContinuation = nil
            }
        }
    }

    private static func keyName(_ key: RemoteKey) -> String? {
        switch key {
        case .power, .powerOff: "KEY_POWER"
        case .up: "KEY_UP"
        case .down: "KEY_DOWN"
        case .left: "KEY_LEFT"
        case .right: "KEY_RIGHT"
        case .select, .enter: "KEY_ENTER"
        case .back, .backspace: "KEY_RETURN"
        case .home: "KEY_HOME"
        case .menu: "KEY_MENU"
        case .info: "KEY_INFO"
        case .input: "KEY_SOURCE"
        case .search: nil
        case .volumeUp: "KEY_VOLUP"
        case .volumeDown: "KEY_VOLDOWN"
        case .mute: "KEY_MUTE"
        case .channelUp: "KEY_CHUP"
        case .channelDown: "KEY_CHDOWN"
        case .playPause: "KEY_PLAY"
        case .rewind: "KEY_REWIND"
        case .fastForward: "KEY_FF"
        case .exit: "KEY_EXIT"
        case .digit(let n): "KEY_\(n)"
        }
    }
}
