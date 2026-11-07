import AVFoundation
import Foundation

/// Captures microphone audio and converts it to the Android TV voice format:
/// 16-bit little-endian PCM, mono, 8 kHz, in ~20 KB chunks.
@MainActor
final class AudioCapture {
    enum State {
        case idle
        case recording
        case failed(String)
    }
    
    private(set) var state: State = .idle
    var onChunk: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private let targetSampleRate: Double = 8000
    private let targetChannels: AVAudioChannelCount = 1
    private let chunkSize = 20_000
    private var buffer: Data = Data()
    
    func checkPermission() async -> Bool {
        #if os(macOS)
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                MainActor.assumeIsolated {
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        let status = AVAudioApplication.shared.recordPermission
        if status == .undetermined {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    MainActor.assumeIsolated {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
        return status == .granted
        #endif
    }
    
    func start() throws {
        guard state == .idle else { return }
        
        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            throw AudioCaptureError.formatError
        }
        
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterError
        }
        
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            MainActor.assumeIsolated {
                self?.process(buffer, converter: converter, outputFormat: outputFormat)
            }
        }
        
        engine = audioEngine
        inputNode = input
        buffer = Data()
        
        try audioEngine.start()
        state = .recording
    }
    
    func stop() {
        guard state == .recording else { return }
        inputNode?.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        inputNode = nil
        if !buffer.isEmpty {
            onChunk?(buffer)
            buffer = Data()
        }
        state = .idle
    }
    
    private func process(_ pcmBuffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(Double(pcmBuffer.frameLength) * targetSampleRate / pcmBuffer.format.sampleRate) + 1
        ) else {
            return
        }
        
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        
        guard status != .error, error == nil, let channelData = outputBuffer.int16ChannelData else {
            return
        }
        
        let frameLength = Int(outputBuffer.frameLength)
        let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
        var data = Data(capacity: frameLength * 2)
        for sample in samples {
            var littleEndian = sample.littleEndian
            data.append(UnsafeBufferPointer(start: &littleEndian, count: 1))
        }
        
        buffer.append(data)
        
        while buffer.count >= chunkSize {
            let chunk = buffer.prefix(chunkSize)
            buffer.removeFirst(chunkSize)
            onChunk?(chunk)
        }
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case formatError
    case converterError
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .formatError: "Couldn't create audio format"
        case .converterError: "Couldn't create audio converter"
        case .permissionDenied: "Microphone permission denied"
        }
    }
}
