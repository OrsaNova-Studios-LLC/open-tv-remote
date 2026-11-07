import SwiftUI

struct RemoteScreen: View {
    @Environment(AppModel.self) private var model
    private var mode: PadMode {
        switch model.remoteControlMode {
        case .keyboard: .keyboard
        case .keypad: .keypad
        default: .dpad
        }
    }
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            TopBar()
            StatusBanner()
            switch model.remoteControlMode {
            case .standard, .keyboard, .keypad: standardMode
            case .eyesFree: JoystickScreen()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(action: handleKey)
        .onAppear { focused = true }
    }

    private var standardMode: some View {
        RemoteModeLayout { navRow } controls: { standardControls }
    }

    private var standardControls: some View {
        GeometryReader { geo in
            let spacing: CGFloat = geo.size.height < 620 ? 10 : 18
            let fixed: CGFloat = 192 + spacing * 2 + 28
            let padHeight = mode == .keyboard
                ? max(300, geo.size.height - (fixed - 192 - spacing))
                : min(340, max(170, geo.size.height - fixed))
            ScrollView {
                VStack(spacing: spacing) {
                    pad
                        .frame(height: padHeight)
                        .padding(.vertical, 4)
                    if mode != .keyboard { controls }
                }
                .padding(.bottom, 20)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var navRow: some View {
        RemoteNavigationRow(selection: Binding(get: { model.remoteControlMode }, set: {
            Haptics.tap()
            model.selectRemoteMode($0)
        }), modes: model.availableRemoteModes, enabled: model.remoteCommandsAvailable,
        back: { model.press(.back) }, home: { model.press(.home) })
    }

    @ViewBuilder private var pad: some View {
        switch mode {
        case .dpad: DPadView()
        case .keyboard: KeyboardPadView()
        case .keypad: KeypadView()
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(spacing: 12) {
                    RemoteKeyButton(key: .menu, symbol: "line.3.horizontal")
                    RemoteKeyButton(key: .info, symbol: "info.circle")
                }
                VStack(spacing: 12) {
                    RemoteKeyButton(key: .input, symbol: "rectangle.portrait.and.arrow.right")
                    RemoteKeyButton(key: .search, symbol: "magnifyingglass")
                }
                Rocker(label: "CH", up: .channelUp, down: .channelDown, upSymbol: "chevron.up", downSymbol: "chevron.down")
                Rocker(label: "VOL", up: .volumeUp, down: .volumeDown, upSymbol: "plus", downSymbol: "minus")
            }
            .frame(height: 124)

            HStack(spacing: 12) {
                RemoteKeyButton(key: .rewind, symbol: "backward.fill", repeats: true)
                RemoteKeyButton(key: .playPause, symbol: "playpause.fill")
                RemoteKeyButton(key: .fastForward, symbol: "forward.fill", repeats: true)
                if model.supportsVoice {
                    MicButton()
                } else {
                    RemoteKeyButton(key: .mute, symbol: "speaker.slash.fill")
                }
            }
            .frame(height: 56)
        }
    }

    /// Hardware keyboard control (Mac, or iPad with a keyboard).
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.remoteCommandsAvailable else { return .ignored }
        if mode == .keyboard, let result = typeKey(press) { return result }
        let key: RemoteKey? = switch press.key {
        case .upArrow: .up
        case .downArrow: .down
        case .leftArrow: .left
        case .rightArrow: .right
        case .return: .select
        case .escape, .delete: .back
        case .space: .playPause
        default:
            switch press.characters.lowercased() {
            case "h": .home
            case "m": .mute
            case "=", "+": .volumeUp
            case "-", "_": .volumeDown
            case "]": .channelUp
            case "[": .channelDown
            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9": .digit(Int(press.characters)!)
            default: nil
            }
        }
        if press.characters == "k" {
            model.showingKeyboard = true
            return .handled
        }
        guard let key else { return .ignored }
        model.press(key)
        return .handled
    }

    /// With the keyboard pad showing, typing goes to the TV instead of triggering shortcuts.
    private func typeKey(_ press: KeyPress) -> KeyPress.Result? {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        switch press.key {
        case .return:
            model.typeReturn()
        case .delete:
            model.typeDelete()
        case .upArrow, .downArrow, .leftArrow, .rightArrow, .escape:
            return nil
        default:
            guard let c = press.characters.first, press.characters.count == 1, !c.isNewline,
                  c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            model.type(press.characters)
        }
        return .handled
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            // Where the TV has a separate full power-off (Samsung), holding the key sends it.
            KeyCap(shape: Circle(), tint: Theme.power, accessibilityLabel: "Power",
                   holdAction: model.supports(.powerOff) ? { model.press(.powerOff) } : nil,
                   holdName: "Turn off TV") {
                model.press(.power)
            } label: {
                Image(systemName: "power").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.power)
            }
            .frame(width: 48, height: 48)

            Button { model.showingDevices = true } label: {
                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        Text(model.current?.name ?? "Choose a TV")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                    }
                    StatusLine()
                }
                .foregroundStyle(Theme.label)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose which TV to control")

            KeyCap(shape: Circle(), accessibilityLabel: "Keyboard") {
                model.showingKeyboard = true
            } label: {
                Image(systemName: "keyboard").font(.system(size: 16, weight: .semibold))
            }
            .frame(width: 48, height: 48)

            SettingsButton().frame(width: 48, height: 48)
        }
    }
}

private struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (text, color): (String, Color) = switch model.state {
        case .connected: ("Connected", Theme.accent)
        case .connecting: ("Connecting…", .yellow)
        case .pairing: ("Pairing…", .yellow)
        case .unpaired: ("Not paired yet", .orange)
        case .failed: ("Not connected", Theme.power)
        case .idle: (model.current == nil ? "No TV selected" : "Ready", Theme.secondary)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: - Status banner

private struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.current == nil {
            card(symbol: "sparkle.magnifyingglass", title: "Let's find your TV",
                 message: "Open Remote works with Google TV, Android TV, Roku, Samsung and LG TVs on your Wi-Fi.",
                 action: "Find TVs") { model.showingDevices = true }
        } else if let device = model.current {
            switch model.state {
            case .unpaired:
                card(symbol: "link", title: "Pair with \(device.name)",
                     message: device.brand.pairingExplanation, action: "Pair") { model.startPairing() }
            case .failed where model.isRelocating:
                card(symbol: "dot.radiowaves.left.and.right", title: "Looking for \(device.name)…",
                     message: "It may have moved to a new address on your network.", action: nil) {}
            case .failed(let message):
                card(symbol: "wifi.exclamationmark", title: "Can't reach \(device.name)",
                     message: message, action: "Try again") { model.reconnect() }
            default:
                EmptyView()
            }
        }
    }

    private func card(symbol: String, title: String, message: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Theme.label)
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action: perform) {
                        Text(action)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(Theme.accent))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                } else {
                    ProgressView().controlSize(.small).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Pieces

private struct Rocker: View {
    @Environment(AppModel.self) private var model
    let label: String
    let up: RemoteKey
    let down: RemoteKey
    let upSymbol: String
    let downSymbol: String

    var body: some View {
        VStack(spacing: 2) {
            KeyCap(shape: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 22, style: .continuous),
                   repeats: true, enabled: model.supports(up), accessibilityLabel: up.accessibilityName) {
                model.press(up)
            } label: {
                Image(systemName: upSymbol).font(.system(size: 19, weight: .bold)).padding(.bottom, 10)
            }
            KeyCap(shape: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 22, bottomTrailingRadius: 22, topTrailingRadius: 6, style: .continuous),
                   repeats: true, enabled: model.supports(down), accessibilityLabel: down.accessibilityName) {
                model.press(down)
            } label: {
                Image(systemName: downSymbol).font(.system(size: 19, weight: .bold)).padding(.top, 10)
            }
        }
        .overlay {
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(1)
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.background))
                .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 1))
                .allowsHitTesting(false)
        }
    }
}

struct AppTile: View {
    let app: TVApp
    let style: CatalogApp?
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button {
            Haptics.tap()
            action()
        } label: {
            ZStack {
                if let style {
                    shape.fill(style.background)
                    if let iconName = style.iconName {
                        Image(iconName)
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 56, maxHeight: 28)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .accessibilityHidden(true)
                    } else {
                        Text(style.name)
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(style.foreground)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 24)
                    }
                } else if let icon = app.iconURL {
                    shape.fill(Theme.keyTop)
                    AsyncImage(url: icon) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Text(app.name).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.label)
                    }
                    .clipShape(shape)
                } else {
                    KeySurface(shape: shape)
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.label)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }
            }
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Open \(app.name)")
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

// MARK: - Mic button

private struct MicButton: View {
    @Environment(AppModel.self) private var model
    @GestureState private var isHolding = false
    
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            KeySurface(shape: shape)
            Image(systemName: model.isRecordingVoice ? "mic.fill" : "mic")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(model.isRecordingVoice ? Theme.accent : Theme.label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
        .gesture(
            LongPressGesture(minimumDuration: 0)
                .updating($isHolding) { value, state, _ in
                    state = value
                }
                .onEnded { _ in }
        )
        .onChange(of: isHolding) { _, holding in
            if holding {
                Task { await model.startVoice() }
            } else {
                model.stopVoice()
            }
        }
        .accessibilityLabel("Hold to talk")
        .accessibilityHint("Hold to send voice to your TV")
    }
}
