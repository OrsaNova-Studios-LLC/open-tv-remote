import SwiftUI

struct JoystickScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("page") private var page = 0

    var body: some View {
        JoystickControls(tvName: model.current?.name ?? "No TV selected", enabled: model.remoteInputAvailable && page == 0,
                         sessionID: model.currentID, inputLog: inputLog,
                         mode: Binding(get: { model.remoteControlMode }, set: {
                             Haptics.tap(); model.selectRemoteMode($0)
                         }), modes: model.availableRemoteModes) { key, request in
            guard model.remoteInputAvailable, page == 0, model.remoteControlMode == .eyesFree, !request.isCancelled else { return }
            switch request.feedback {
            case .firm:
                switch key {
                case .up, .down, .left, .right: Haptics.joystickStart()
                case .select: Haptics.tick()
                default: Haptics.tap()
                }
            case .soft: Haptics.joystickRepeat()
            case .none: break
            }
            await model.pressInteractively(key, request: request)
        }
    }

    private var inputLog: String? {
        #if DEBUG
        if DemoMode.isEnabled && UserDefaults.standard.bool(forKey: "demoInputLog") {
            return "\(model.demoInputCount):\(model.demoLastInput)"
        }
        #endif
        return nil
    }
}

private struct JoystickControls: View {
    @Environment(\.scenePhase) private var scenePhase
    let tvName: String
    let enabled: Bool
    let sessionID: String?
    let inputLog: String?
    @Binding var mode: RemoteControlMode
    let modes: [RemoteControlMode]
    @State private var input = JoystickGesture()
    @State private var sender: JoystickSender
    @GestureState private var touching = false
    @State private var ignoreUntilLift = false

    init(tvName: String, enabled: Bool, sessionID: String?, inputLog: String? = nil,
         mode: Binding<RemoteControlMode> = .constant(.eyesFree), modes: [RemoteControlMode] = RemoteControlMode.allCases,
         send: @escaping (RemoteKey, RemoteInputRequest) async -> Void) {
        self.tvName = tvName
        self.enabled = enabled
        self.sessionID = sessionID
        self.inputLog = inputLog
        self._mode = mode
        self.modes = modes
        _sender = State(initialValue: JoystickSender(send: send))
    }

    var body: some View {
        RemoteModeLayout {
            RemoteNavigationRow(selection: $mode, modes: modes, enabled: enabled,
                                back: { press(.back) }, home: { press(.home) })
        } controls: {
            VStack(spacing: 16) {
                VStack(spacing: 5) {
                    Text(enabled ? "Touch anywhere. Drag to move." : "Connect to a TV first.")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(enabled ? "Tap for OK · Hold a direction to repeat" : "Choose or connect to a TV above.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                surface.frame(minHeight: 160)
                if let inputLog {
                    Text(inputLog).font(.caption.monospaced()).accessibilityIdentifier("eyesFreeInputLog")
                }
                Button { press(.back) } label: {
                    Label("Back", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity).frame(height: 80)
                        .background(RoundedRectangle(cornerRadius: 24).fill(Theme.keyTop))
                }
                .buttonStyle(.plain).disabled(!enabled)
                .accessibilityIdentifier("eyesFreeBack")
            }
        }
        .foregroundStyle(Theme.label)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: touching) { _, active in
            if !active { endContact() }
        }
        .onChange(of: enabled) { _, _ in cancel() }
        .onChange(of: sessionID) { _, _ in cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
        .onDisappear { cancel() }
    }

    private var surface: some View {
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 32).fill(Theme.well)
                    RoundedRectangle(cornerRadius: 32).strokeBorder(Theme.accent.opacity(enabled ? 0.18 : 0.05))
                    if let origin = input.origin {
                        stick.position(origin)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "hand.draw").font(.system(size: 48, weight: .light))
                            Text("Your thumb sets the center")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(Theme.secondary.opacity(0.65))
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    VStack {
                        Text(input.direction?.accessibilityName ?? (touching ? "Rest to pause" : "Ready when you are"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.accent.opacity(enabled ? 0.8 : 0.3))
                            .padding(.top, 20)
                        Spacer()
                    }
            }
            .clipped()
            .contentShape(RoundedRectangle(cornerRadius: 32))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($touching) { _, active, _ in active = true }
                .onChanged { value in
                    guard enabled, scenePhase == .active, !ignoreUntilLift else { return }
                    let previous = input.direction
                    input.update(start: value.startLocation, location: value.location,
                                 time: ProcessInfo.processInfo.systemUptime)
                    if previous != input.direction { sender.hold(input.direction) }
                }
                .onEnded { value in
                    guard enabled, scenePhase == .active else { cancel(); return }
                    guard !ignoreUntilLift else { endContact(); return }
                    let select = input.finish(location: value.location, time: ProcessInfo.processInfo.systemUptime)
                    sender.release()
                    if select { sender.press(.select) }
                })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Floating directional stick")
        .accessibilityHint("Drag in a direction and hold to repeat. A short tap selects. Lift to stop.")
        .accessibilityValue(enabled ? (input.direction?.accessibilityName ?? "Ready") : "Not connected")
        .accessibilityIdentifier("eyesFreeStick")
        .accessibilityAction { press(.select) }
        .accessibilityActions {
            Button("Move up") { press(.up) }
            Button("Move down") { press(.down) }
            Button("Move left") { press(.left) }
            Button("Move right") { press(.right) }
        }
    }

    private var stick: some View {
        let offset = input.offset
        let distance = hypot(offset.width, offset.height)
        let scale = distance > 52 ? 52 / distance : 1
        return ZStack {
            Circle().fill(Theme.accent.opacity(0.05)).frame(width: 144, height: 144)
            Circle().strokeBorder(Theme.accent.opacity(0.28), lineWidth: 2).frame(width: 144, height: 144)
            Circle().strokeBorder(Theme.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                .frame(width: 48, height: 48)
            Circle().fill(Theme.accent.opacity(input.direction == nil ? 0.35 : 0.85))
                .frame(width: 56, height: 56)
                .offset(x: offset.width * scale, y: offset.height * scale)
        }
    }

    private func press(_ key: RemoteKey) {
        guard enabled, scenePhase == .active else { return }
        ignoreUntilLift = touching
        input.cancel()
        sender.press(key)
    }

    private func endContact() {
        input.cancel()
        sender.release()
        ignoreUntilLift = false
    }

    private func cancel() {
        ignoreUntilLift = touching
        input.cancel()
        sender.stop()
    }
}

#Preview("Eyes-free") {
    JoystickControls(tvName: "Living Room TV", enabled: true, sessionID: "preview") { _, _ in }
        .frame(width: 390, height: 844)
}

#Preview("Not connected") {
    JoystickControls(tvName: "Living Room TV", enabled: false, sessionID: "preview") { _, _ in }
        .frame(width: 390, height: 844)
}
