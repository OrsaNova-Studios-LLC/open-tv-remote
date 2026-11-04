import CryptoKit
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Android TV Remote Service protocol v2 — the same one Google's own TV remote uses.
/// Works with every Google TV / Android TV (Sony, TCL, Hisense, Philips, Chromecast, Shield…).
///
/// Port 6467: one-time pairing. The TV shows a 6-hex-digit code; we prove we saw it by
///            hashing it together with both certificates' RSA keys.
/// Port 6466: the remote session itself, authenticated by our client certificate.
@MainActor
final class AndroidTVDriver: TVDriver {
    private(set) var device: TVDevice
    weak var delegate: TVDriverDelegate?
    private(set) var state: ConnectionState = .idle {
        didSet { if state != oldValue { delegate?.driver(self, didChangeState: state) } }
    }

    private var remote: TLSChannel?
    private var pairing: TLSChannel?
    private var pendingKeys: [RemoteKey] = []
    /// An app launch requested while (re)connecting; the TV drops idle sessions, so this is common.
    private var pendingLaunch: TVApp?
    /// Package name of the app in the foreground, as reported by the TV.
    private(set) var currentApp: String?
    private var imeCounter = 0
    private var imeFieldCounter = 0
    /// Shown alongside the next code prompt (e.g. after a wrong code forces a fresh one).
    private var nextPairingError: String?

    /// PING | KEY | IME | POWER | VOLUME | APP_LINK
    private static let requestedFeatures = 1 | 2 | 4 | 32 | 64 | 512
    private var activeFeatures = requestedFeatures

    init(device: TVDevice) {
        self.device = device
    }

    // MARK: Connection

    func connect() {
        guard device.isPaired else {
            state = .unpaired
            return
        }
        openRemote()
    }

    func disconnect() {
        pendingKeys = []
        pendingLaunch = nil
        remote?.onClose = nil
        remote?.cancel()
        remote = nil
        pairing?.onClose = nil
        pairing?.cancel()
        pairing = nil
        state = .idle
    }

    private func openRemote() {
        guard remote == nil else { return }
        let identity: ClientIdentity.Material
        do { identity = try ClientIdentity.loadOrCreate() } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .connecting
        let channel = TLSChannel(host: device.host, port: 6466, identity: identity.identity)
        channel.onMessage = { [weak self] in self?.handleRemote($0) }
        channel.onClose = { [weak self] error, tlsRejected in
            guard let self else { return }
            let wasConnected = self.state == .connected
            self.remote = nil
            if tlsRejected && !wasConnected {
                // The TV no longer knows our certificate (reset, or pairing removed on the TV).
                self.device.isPaired = false
                self.delegate?.driver(self, didUpdateDevice: self.device)
                self.state = .unpaired
            } else if wasConnected {
                // TVs drop idle sessions. Go quiet; the next key press reconnects.
                self.state = .idle
            } else {
                self.state = .failed(Self.describe(error))
            }
        }
        remote = channel
        channel.start()
    }

    private func handleRemote(_ msg: ProtoMessage) {
        var reply = ProtoWriter()
        if let configure = msg.message(1) {
            let supported = configure.int(1) ?? Self.requestedFeatures
            activeFeatures = Self.requestedFeatures & (supported == 0 ? Self.requestedFeatures : supported)
            if let info = configure.message(2), let model = info.string(1), !model.isEmpty, device.model == nil {
                device.model = [info.string(2), model].compactMap { $0 }.joined(separator: " ")
                delegate?.driver(self, didUpdateDevice: device)
            }
            reply.message(1) { c in
                c.int(1, activeFeatures)
                c.message(2) { d in
                    d.int(3, 1)
                    d.string(4, "1")
                    d.string(5, "atvremote")
                    d.string(6, "1.0.0")
                }
            }
        } else if msg.has(2) {
            reply.message(2) { $0.int(1, activeFeatures) }
            markConnected()
        } else if let ping = msg.message(8) {
            reply.message(9) { $0.int(1, ping.int(1) ?? 0) }
        } else if msg.has(40) {
            markConnected()
            return
        } else if let inject = msg.message(20) {
            currentApp = inject.message(1)?.string(12)
            return
        } else if let edit = msg.message(21) {
            imeCounter = edit.int(1) ?? imeCounter
            imeFieldCounter = edit.int(2) ?? imeFieldCounter
            return
        } else {
            return
        }
        remote?.send(reply)
    }

    private func markConnected() {
        guard state != .connected else { return }
        state = .connected
        let queued = pendingKeys
        pendingKeys = []
        queued.forEach(send)
        if let app = pendingLaunch {
            pendingLaunch = nil
            launch(app)
        }
    }

    // MARK: Pairing

    func pair() {
        disconnect()
        state = .connecting
        openPairingChannel()
    }

    /// Opens the pairing socket without touching `state`, so a retry can keep the code prompt on screen.
    private func openPairingChannel() {
        let identity: ClientIdentity.Material
        do { identity = try ClientIdentity.loadOrCreate() } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let channel = TLSChannel(host: device.host, port: 6467, identity: identity.identity)
        channel.onReady = { [weak self] in
            self?.sendPairing { m in
                m.message(10) { r in
                    r.string(1, "atvremote")
                    r.string(2, Self.clientName(for: identity.certificate))
                }
            }
        }
        channel.onMessage = { [weak self] in self?.handlePairing($0) }
        channel.onClose = { [weak self] error, _ in
            guard let self, self.pairing != nil else { return }
            self.pairing = nil
            if !self.device.isPaired {
                self.state = .failed("Pairing was interrupted. \(Self.describe(error))")
            }
        }
        pairing = channel
        channel.start()
    }

    private func sendPairing(_ build: (inout ProtoWriter) -> Void) {
        var m = ProtoWriter()
        m.uint(1, 2)   // protocol_version
        m.uint(2, 200) // STATUS_OK
        build(&m)
        pairing?.send(m)
    }

    private func handlePairing(_ msg: ProtoMessage) {
        let status = msg.uint(2) ?? 0
        guard status == 200 else {
            pairing?.onClose = nil
            pairing?.cancel()
            pairing = nil
            if status == 402 {
                // The TV discards a code after one failed attempt; ask for a fresh one,
                // keeping the prompt up so the sheet doesn't close and reopen.
                let message = "That code didn't work. Your TV is showing a new one."
                nextPairingError = message
                state = .pairing(.enterCode(length: 6, error: message))
                openPairingChannel()
                return
            }
            state = .failed("The TV declined pairing (status \(status)).")
            return
        }
        // Hexadecimal code, 6 symbols, we are the input side.
        let encoding: (inout ProtoWriter) -> Void = { e in
            e.uint(1, 3)
            e.uint(2, 6)
        }
        if msg.has(11) {
            sendPairing { m in
                m.message(20) { o in
                    o.message(1, encoding)
                    o.uint(3, 1)
                }
            }
        } else if msg.has(20) {
            sendPairing { m in
                m.message(30) { c in
                    c.message(1, encoding)
                    c.uint(2, 1)
                }
            }
        } else if msg.has(31) {
            state = .pairing(.enterCode(length: 6, error: nextPairingError))
            nextPairingError = nil
        } else if msg.has(41) {
            device.isPaired = true
            delegate?.driver(self, didUpdateDevice: device)
            let channel = pairing
            pairing = nil
            channel?.cancel()
            openRemote()
        }
    }

    func submitPairingCode(_ raw: String) {
        let code = raw.uppercased().filter { !$0.isWhitespace }
        guard code.count == 6, code.allSatisfy(\.isHexDigit) else {
            state = .pairing(.enterCode(length: 6, error: "Codes are 6 characters: 0–9 and A–F."))
            return
        }
        guard let serverCert = pairing?.peerCertificate,
              let identity = try? ClientIdentity.loadOrCreate(),
              let client = ClientIdentity.rsaComponents(of: identity.certificate),
              let server = ClientIdentity.rsaComponents(of: serverCert) else {
            state = .failed("Lost the pairing connection. Start pairing again.")
            return
        }
        let codeBytes = stride(from: 0, to: 6, by: 2).map { i -> UInt8 in
            let start = code.index(code.startIndex, offsetBy: i)
            return UInt8(code[start..<code.index(start, offsetBy: 2)], radix: 16)!
        }
        var hash = SHA256()
        hash.update(data: client.modulus)
        hash.update(data: client.exponent)
        hash.update(data: server.modulus)
        hash.update(data: server.exponent)
        hash.update(data: Array(codeBytes.dropFirst()))
        let secret = Array(hash.finalize())
        // The first byte of the code is a checksum: catches typos without a round trip.
        guard secret[0] == codeBytes[0] else {
            state = .pairing(.enterCode(length: 6, error: "That code doesn't match. Check the TV and try again."))
            return
        }
        state = .pairing(.verifying)
        sendPairing { m in m.message(40) { $0.data(1, secret) } }
    }

    // MARK: Commands

    func supports(_ key: RemoteKey) -> Bool { Self.keyCode(key) != nil }

    func send(_ key: RemoteKey) {
        guard let code = Self.keyCode(key) else { return }
        guard state == .connected, let remote else {
            if device.isPaired {
                if pendingKeys.count < 10 { pendingKeys.append(key) }
                openRemote()
            }
            return
        }
        var m = ProtoWriter()
        m.message(10) { k in
            k.uint(1, UInt64(code))
            k.uint(2, 3) // SHORT press
        }
        remote.send(m)
    }

    func sendInteractive(_ key: RemoteKey, request: RemoteInputRequest) async {
        guard state == .connected, !request.isCancelled, !Task.isCancelled, let code = Self.keyCode(key), let remote else { return }
        var message = ProtoWriter()
        message.message(10) { key in
            key.uint(1, UInt64(code))
            key.uint(2, 3)
        }
        await remote.sendAndWait(message)
    }

    func sendText(_ text: String) {
        guard !text.isEmpty, state == .connected else { return }
        let cursor = text.count - 1
        var m = ProtoWriter()
        m.message(21) { b in
            b.int(1, imeCounter)
            b.int(2, imeFieldCounter)
            b.message(3) { e in
                e.int(1, 1)
                e.message(2) { o in
                    o.int(1, cursor)
                    o.int(2, cursor)
                    o.string(3, text)
                }
            }
        }
        remote?.send(m)
    }

    func launch(_ app: TVApp) {
        guard state == .connected else {
            if device.isPaired {
                pendingLaunch = app
                openRemote()
            }
            return
        }
        var m = ProtoWriter()
        m.message(90) { $0.string(1, app.launchID) }
        remote?.send(m)
    }

    func installedApps() async -> [TVApp]? { nil }

    // MARK: Helpers

    /// Shown on the TV while pairing. Tagged with the certificate's fingerprint so people can tell
    /// their devices apart. (What keeps pairings separate is the certificate; see ClientIdentity.)
    static func clientName(for certificate: SecCertificate) -> String {
        #if os(macOS)
        let kind = "Mac"
        #else
        let kind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
        return "Open Remote (\(kind) \(ClientIdentity.shortID(of: certificate)))"
    }

    private static func describe(_ error: NWError?) -> String {
        guard let error else { return "The TV closed the connection." }
        switch error {
        case .posix(let code) where code == .ECONNREFUSED: return "The TV refused the connection."
        case .posix(let code) where code == .ETIMEDOUT || code == .EHOSTUNREACH || code == .EHOSTDOWN:
            return "Couldn't reach the TV. Is it on and on the same Wi-Fi?"
        default: return "Couldn't connect to the TV."
        }
    }

    /// Android KeyEvent codes.
    private static func keyCode(_ key: RemoteKey) -> Int? {
        switch key {
        case .power: 26
        case .powerOff: nil
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        case .select: 23
        case .back, .exit: 4
        case .home: 3
        case .menu: 82
        case .info: 165
        case .input: 178
        case .search: 84
        case .volumeUp: 24
        case .volumeDown: 25
        case .mute: 164
        case .channelUp: 166
        case .channelDown: 167
        case .playPause: 85
        case .rewind: 89
        case .fastForward: 90
        case .backspace: 67
        case .enter: 66
        case .digit(let n): (0...9).contains(n) ? 7 + n : nil
        }
    }
}
