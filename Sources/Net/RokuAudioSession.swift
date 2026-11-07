import AVFoundation
import AudioToolbox
import Foundation

@MainActor
final class RokuAudioSession {
    private let host: String
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isConfigured = false
    
    var onError: ((String) -> Void)?
    
    init(host: String) {
        self.host = host
    }
    
    func start() async throws {
        guard let url = URL(string: "ws://\(host):8060/ecp-session") else {
            throw AudioSessionError.invalidURL
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        
        let session = URLSession(configuration: config, delegate: WebSocketDelegate(owner: self), delegateQueue: .main)
        self.session = session
        
        var request = URLRequest(url: url)
        request.setValue("ecp-2", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        
        socket.resume()
        
        receiveMessages()
        
        try await sendCommand(["type": "hello"])
        try await Task.sleep(for: .milliseconds(100))
        try await requestAudio()
    }
    
    func stop() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        playerNode.stop()
        
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    
    private func setupAudioEngine() throws {
        guard !isConfigured else { return }
        
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        #endif
        
        audioEngine.attach(playerNode)
        
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        
        try audioEngine.start()
        playerNode.play()
        
        isConfigured = true
    }
    
    private func sendCommand(_ json: [String: Any]) async throws {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else {
            throw AudioSessionError.encodingFailed
        }
        
        try await socket?.send(.string(text))
    }
    
    private func requestAudio() async throws {
        try await sendCommand([
            "type": "audio",
            "params": [
                "output": "datagram"
            ]
        ])
    }
    
    private func receiveMessages() {
        guard let socket else { return }
        
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.receiveMessages()
                    
                case .failure(let error):
                    self.handleError(error)
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleTextMessage(text)
            
        case .data(let data):
            handleBinaryMessage(data)
            
        @unknown default:
            break
        }
    }
    
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        
        if type == "error" {
            let message = (json["message"] as? String) ?? "Unknown error"
            onError?("Roku error: \(message)")
        }
    }
    
    private func handleBinaryMessage(_ data: Data) {
        guard data.count > 12 else { return }
        
        do {
            if !isConfigured {
                try setupAudioEngine()
            }
            
            try processAudioPacket(data)
        } catch {
            onError?("Audio playback error: \(error.localizedDescription)")
        }
    }
    
    private var audioConverter: AudioConverterRef?
    private var opusFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    
    private func processAudioPacket(_ data: Data) throws {
        let rtpHeaderSize = 12
        guard data.count > rtpHeaderSize else { return }
        
        let payloadData = data.dropFirst(rtpHeaderSize)
        guard !payloadData.isEmpty else { return }
        
        if audioConverter == nil {
            try setupOpusConverter()
        }
        
        guard let converter = audioConverter,
              let pcmFormat = pcmFormat else {
            throw AudioSessionError.converterCreationFailed
        }
        
        let frameCount = AVAudioFrameCount(960)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
            throw AudioSessionError.bufferCreationFailed
        }
        
        var ioOutputDataPacketSize = frameCount
        
        let audioBufferList = buffer.mutableAudioBufferList
        
        let status = payloadData.withUnsafeBytes { (rawPointer: UnsafeRawBufferPointer) -> OSStatus in
            var inBuffer = AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(payloadData.count),
                mData: UnsafeMutableRawPointer(mutating: rawPointer.baseAddress)
            )
            
            var inBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: inBuffer
            )
            
            return AudioConverterFillComplexBuffer(
                converter,
                opusInputCallback,
                &inBufferList,
                &ioOutputDataPacketSize,
                audioBufferList,
                nil
            )
        }
        
        if status == noErr {
            buffer.frameLength = ioOutputDataPacketSize
            if playerNode.engine != nil, buffer.frameLength > 0 {
                playerNode.scheduleBuffer(buffer)
            }
        }
    }
    
    private func setupOpusConverter() throws {
        var opusDesc = AudioStreamBasicDescription()
        opusDesc.mSampleRate = 48000
        opusDesc.mFormatID = kAudioFormatOpus
        opusDesc.mFormatFlags = 0
        opusDesc.mBytesPerPacket = 0
        opusDesc.mFramesPerPacket = 960
        opusDesc.mBytesPerFrame = 0
        opusDesc.mChannelsPerFrame = 2
        opusDesc.mBitsPerChannel = 0
        
        opusFormat = AVAudioFormat(streamDescription: &opusDesc)
        
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        pcmFormat = targetFormat
        
        var targetDesc = targetFormat.streamDescription.pointee
        
        var converter: AudioConverterRef?
        let status = AudioConverterNew(&opusDesc, &targetDesc, &converter)
        
        guard status == noErr, let converter else {
            throw AudioSessionError.converterCreationFailed
        }
        
        audioConverter = converter
    }
    
    private let opusInputCallback: AudioConverterComplexInputDataProc = { (
        converter,
        ioNumberDataPackets,
        ioData,
        outDataPacketDescription,
        inUserData
    ) -> OSStatus in
        guard let inUserData else { return kAudioConverterErr_InvalidInputSize }
        
        let bufferList = inUserData.assumingMemoryBound(to: AudioBufferList.self)
        ioData.pointee = bufferList.pointee
        
        return noErr
    }
    
    private func handleError(_ error: Error) {
        onError?("Connection error: \(error.localizedDescription)")
    }
    
    private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        weak var owner: RokuAudioSession?
        
        init(owner: RokuAudioSession) {
            self.owner = owner
        }
        
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                       didOpenWithProtocol protocol: String?) {
        }
        
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                       didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            MainActor.assumeIsolated {
                self.owner?.onError?("Audio session closed")
            }
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                MainActor.assumeIsolated {
                    self.owner?.handleError(error)
                }
            }
        }
    }
}

enum AudioSessionError: LocalizedError {
    case invalidURL
    case encodingFailed
    case converterCreationFailed
    case bufferCreationFailed
    case conversionFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid audio session URL"
        case .encodingFailed: "Failed to encode command"
        case .converterCreationFailed: "Failed to create audio converter"
        case .bufferCreationFailed: "Failed to create audio buffer"
        case .conversionFailed: "Failed to convert audio"
        }
    }
}
