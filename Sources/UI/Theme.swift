import SwiftUI
#if os(iOS)
import UIKit
#endif

enum Theme {
    static let background = Color(red: 0.035, green: 0.037, blue: 0.045)
    static let keyTop = Color(white: 0.155)
    static let keyBottom = Color(white: 0.105)
    static let well = Color(white: 0.07)
    static let accent = Color(red: 0.36, green: 0.89, blue: 0.65)
    static let power = Color(red: 1.0, green: 0.36, blue: 0.33)
    static let label = Color(white: 0.92)
    static let secondary = Color(white: 0.55)
    static let corner: CGFloat = 18
}

enum Haptics {
    #if os(iOS)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let firm = UIImpactFeedbackGenerator(style: .medium)
    private static let repeatPulse = UIImpactFeedbackGenerator(style: .light)
    #endif

    static func tap() {
        #if os(iOS)
        light.impactOccurred()
        #endif
    }

    static func tick() {
        #if os(iOS)
        rigid.impactOccurred(intensity: 0.6)
        #endif
    }

    static func joystickStart() {
        #if os(iOS)
        firm.impactOccurred(intensity: 0.8)
        repeatPulse.prepare()
        #endif
    }

    static func joystickRepeat() {
        #if os(iOS)
        // Use the standard light impact at its normal strength: gentler than the
        // medium start, but more distinct than a low-intensity soft waveform.
        repeatPulse.impactOccurred()
        repeatPulse.prepare()
        #endif
    }
}

/// The raised, slightly glossy surface every remote key sits on.
struct KeySurface<S: InsettableShape>: View {
    let shape: S
    var pressed = false
    var tint: Color? = nil

    var body: some View {
        shape
            .fill(LinearGradient(colors: pressed ? [Theme.keyBottom, Theme.keyBottom] : [Theme.keyTop, Theme.keyBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                if let tint, pressed { shape.fill(tint.opacity(0.22)) }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(pressed ? 0.05 : 0.11), .white.opacity(0.02)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: .black.opacity(pressed ? 0.2 : 0.55), radius: pressed ? 2 : 7, y: pressed ? 1 : 4)
    }
}

/// A remote button: fires on touch-down (like a physical remote) and can auto-repeat while held.
struct KeyCap<Label: View, S: InsettableShape>: View {
    var shape: S
    var repeats = false
    var tint: Color? = Theme.accent
    var enabled = true
    var accessibilityLabel: String
    /// If set, a short tap fires `action` on release and holding fires this instead.
    var holdAction: (() -> Void)? = nil
    var holdName = "Hold"
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    /// GestureState resets itself when the system cancels a touch (calls, Control Center,
    /// a sheet appearing) — unlike onEnded, which never fires in that case.
    @GestureState private var pressed = false
    @State private var repeatTask: Task<Void, Never>?
    @State private var held = false

    var body: some View {
        label()
            .foregroundStyle(enabled ? Theme.label : Theme.secondary.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeySurface(shape: shape, pressed: pressed, tint: tint))
            .contentShape(shape)
            .scaleEffect(pressed ? 0.955 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
                    // onEnded doesn't run when the system cancels the touch, so a cancelled
                    // hold never turns into a tap.
                    .onEnded { _ in
                        if holdAction != nil && !held { fire() }
                    }
            )
            .onChange(of: pressed) { _, isPressed in
                repeatTask?.cancel()
                guard isPressed else { return }
                if let holdAction {
                    held = false
                    repeatTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(700))
                        guard !Task.isCancelled else { return }
                        held = true
                        Haptics.tick()
                        holdAction()
                    }
                    return
                }
                fire()
                if repeats { startRepeating() }
            }
            .onDisappear { repeatTask?.cancel() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { fire() }
            .accessibilityActions {
                if let holdAction { Button(holdName, action: holdAction) }
            }
    }

    private func fire() {
        Haptics.tap()
        action()
    }

    private func startRepeating() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            // Belt and braces: never auto-repeat for more than ~8 seconds.
            for _ in 0..<70 where !Task.isCancelled {
                fire()
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }
}

extension KeyCap where S == RoundedRectangle {
    init(repeats: Bool = false, tint: Color? = Theme.accent, enabled: Bool = true, accessibilityLabel: String,
         action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.init(shape: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous), repeats: repeats, tint: tint,
                  enabled: enabled, accessibilityLabel: accessibilityLabel, action: action, label: label)
    }
}

/// Convenience: a key bound straight to a RemoteKey.
struct RemoteKeyButton: View {
    @Environment(AppModel.self) private var model
    let key: RemoteKey
    let symbol: String
    var repeats = false

    var body: some View {
        KeyCap(repeats: repeats, enabled: model.supports(key), accessibilityLabel: key.accessibilityName) {
            model.press(key)
        } label: {
            Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
        }
    }
}
