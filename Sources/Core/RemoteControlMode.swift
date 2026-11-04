import Foundation

enum RemoteControlMode: String, CaseIterable, Identifiable {
    case standard, keyboard, keypad, eyesFree
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Directional pad"
        case .keyboard: "Keyboard"
        case .keypad: "Number pad"
        case .eyesFree: "Eyes-free"
        }
    }
    var symbol: String {
        switch self {
        case .standard: "dpad.fill"
        case .keyboard: "keyboard.fill"
        case .keypad: "circle.grid.3x3.fill"
        case .eyesFree: "l.joystick.tilt.up.fill"
        }
    }
    var isGestureMode: Bool { self == .eyesFree }

}

/// Only a view preference is saved. Touches, held directions and pending commands are never restored.
@MainActor
struct RemoteModePreferences {
    private let defaults: UserDefaults
    private static let key = "remoteView.modes.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func mode(for deviceID: String?, available: [RemoteControlMode] = RemoteControlMode.allCases) -> RemoteControlMode {
        guard let deviceID,
              let raw = defaults.dictionary(forKey: Self.key)?[deviceID] as? String,
              let mode = RemoteControlMode(rawValue: raw), available.contains(mode) else { return .standard }
        return mode
    }

    func save(_ mode: RemoteControlMode, for deviceID: String?) {
        guard let deviceID else { return }
        var modes = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        modes[deviceID] = mode.rawValue
        defaults.set(modes, forKey: Self.key)
    }

    func move(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        var modes = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        guard let mode = modes.removeValue(forKey: oldID) else { return }
        modes[newID] = mode
        defaults.set(modes, forKey: Self.key)
    }

    func forget(_ deviceID: String) {
        var modes = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        modes.removeValue(forKey: deviceID)
        defaults.set(modes, forKey: Self.key)
    }

    /// The old beta preference applied to its selected TV, not every subsequently selected TV.
    func migrateLegacy(for deviceID: String?) {
        guard let deviceID, !defaults.bool(forKey: "remoteView.legacyMigrated.v1") else { return }
        if defaults.dictionary(forKey: Self.key)?[deviceID] == nil {
            if defaults.bool(forKey: "remoteView.eyesFree.v1") {
                save(.eyesFree, for: deviceID)
            } else if let raw = defaults.string(forKey: "padMode"),
                      let mode = RemoteControlMode(rawValue: raw), !mode.isGestureMode {
                save(mode, for: deviceID)
            }
        }
        defaults.set(true, forKey: "remoteView.legacyMigrated.v1")
        defaults.removeObject(forKey: "remoteView.eyesFree.v1")
    }
}
