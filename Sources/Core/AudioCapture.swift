import Foundation
import AVFAudio

/// Captures microphone audio as 16-bit little-endian PCM at a specified sample rate.
@MainActor
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let sampleRate: Double
    private var isCapturing = false
    private var dataHandler: ((Data) -> Void)?
    
    init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
    }
    
    /// Request microphone permission. Returns true if granted.
    static func requestPermission() async -> Bool {
        #if os(macOS)
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
        #endif
    }
    
    /// Start capturing audio. The handler receives PCM data chunks as they arrive.
    func start(onData: @escaping (Data) -> Void) throws {
        guard !isCapturing else { return }
        
        dataHandler = onData
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatConversionFailed
        }
        
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.formatConversionFailed
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / buffer.format.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            ) else { return }
            
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            guard error == nil else { return }
            
            let channelData = convertedBuffer.int16ChannelData?[0]
            let frameCount = Int(convertedBuffer.frameLength)
            let data = Data(bytes: channelData!, count: frameCount * 2)
            
            Task { @MainActor in
                self.dataHandler?(data)
            }
        }
        
        try engine.start()
        isCapturing = true
    }
    
    /// Stop capturing audio and release resources.
    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        dataHandler = nil
    }
    
    deinit {
        if isCapturing {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}

enum AudioCaptureError: Error {
    case formatConversionFailed
    case permissionDenied
}
