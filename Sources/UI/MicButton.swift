import SwiftUI

/// A hold-to-talk microphone button that captures voice while pressed.
struct MicButton: View {
    @Environment(AppModel.self) private var model
    @GestureState private var isHolding = false
    @State private var isRecording = false
    @State private var errorMessage: String?
    
    var body: some View {
        KeyCap(
            shape: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous),
            tint: .blue,
            enabled: model.state == .connected,
            accessibilityLabel: "Voice"
        ) {
        } label: {
            ZStack {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isRecording ? .white : Theme.label)
                
                if isRecording {
                    Circle()
                        .stroke(lineWidth: 2)
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 40, height: 40)
                        .scaleEffect(isRecording ? 1.2 : 1.0)
                        .opacity(isRecording ? 0.0 : 1.0)
                        .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false), value: isRecording)
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isHolding) { _, state, _ in
                    state = true
                }
        )
        .onChange(of: isHolding) { _, holding in
            if holding {
                startVoice()
            } else {
                stopVoice()
            }
        }
        .onDisappear {
            if isRecording {
                stopVoice()
            }
        }
        .alert("Microphone Permission Required", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    private func startVoice() {
        guard !isRecording else { return }
        
        Task {
            do {
                try await model.startVoice()
                await MainActor.run {
                    isRecording = true
                    Haptics.tick()
                }
            } catch AudioCaptureError.permissionDenied {
                await MainActor.run {
                    errorMessage = "Please allow microphone access in System Settings to use voice commands."
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Could not start voice input. Please try again."
                }
            }
        }
    }
    
    private func stopVoice() {
        guard isRecording else { return }
        model.stopVoice()
        isRecording = false
        Haptics.tap()
    }
}
