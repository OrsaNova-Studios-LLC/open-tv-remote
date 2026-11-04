import Foundation
import Network
import Security

/// A mutual-TLS socket that exchanges varint-framed protobuf messages.
/// TVs use self-signed certificates, so we accept the server's cert and keep it
/// (the pairing secret is derived from it).
@MainActor
final class TLSChannel {
    var onReady: (() -> Void)?
    var onMessage: ((ProtoMessage) -> Void)?
    /// `tlsRejected` is true when the TLS handshake failed — for Android TV that usually
    /// means the TV doesn't recognize our certificate anymore.
    var onClose: ((_ error: NWError?, _ tlsRejected: Bool) -> Void)?

    private(set) var peerCertificate: SecCertificate?
    private let connection: NWConnection
    private var framer = ProtoFramer()
    private var closed = false

    init(host: String, port: UInt16, identity: SecIdentity) {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
        }
        let certBox = CertificateBox()
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate] {
                certBox.certificate = chain.first
            }
            complete(true)
        }, .main)

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 6
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)

        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.peerCertificate = certBox.certificate
                    self.receive()
                    self.onReady?()
                case .failed(let error):
                    self.finish(error)
                case .waiting(let error):
                    // Unreachable host or refused connection: don't hang around forever.
                    self.finish(error)
                case .cancelled:
                    self.finish(nil)
                default:
                    break
                }
            }
        }
    }

    func start() { connection.start(queue: .main) }

    func send(_ message: ProtoWriter) {
        guard !closed else { return }
        connection.send(content: Data(message.framed), completion: .contentProcessed { _ in })
    }

    func sendAndWait(_ message: ProtoWriter) async {
        guard !closed, !Task.isCancelled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(message.framed), completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    func cancel() {
        guard !closed else { return }
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.framer.append(data)
                    while let frame = self.framer.next() {
                        if let msg = ProtoMessage(frame) { self.onMessage?(msg) }
                    }
                }
                if isComplete || error != nil {
                    self.connection.cancel()
                    self.finish(error)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func finish(_ error: NWError?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        // Only the TV's certificate alerts mean it has forgotten us. Other TLS failures (the
        // connection dropping mid-handshake while the TV wakes, Wi-Fi blips) are transient and
        // must not throw away a working pairing.
        var tlsRejected = false
        if case .tls(let status)? = error {
            tlsRejected = [errSSLPeerBadCert, errSSLPeerUnsupportedCert, errSSLPeerCertRevoked,
                           errSSLPeerCertExpired, errSSLPeerCertUnknown, errSSLPeerAccessDenied].contains(status)
        }
        onClose?(error, tlsRejected)
    }
}

private final class CertificateBox: @unchecked Sendable {
    var certificate: SecCertificate?
}
