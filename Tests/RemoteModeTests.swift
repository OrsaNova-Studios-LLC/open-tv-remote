import Foundation
import Testing
@testable import JoystickCore

@Suite("Persistent remote modes")
@MainActor
struct RemoteModeTests {
    private func withPreferences(_ test: (RemoteModePreferences, UserDefaults) -> Void) {
        let name = "RemoteModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(RemoteModePreferences(defaults: defaults), defaults)
    }

    @Test func firstUseStartsWithStandard() {
        withPreferences { modes, _ in
            #expect(modes.mode(for: nil) == .standard)
            #expect(modes.mode(for: "new-tv") == .standard)
        }
    }

    @Test func switchingTVsKeepsIndependentSelectionsAcrossRelaunch() {
        withPreferences { modes, defaults in
            modes.save(.eyesFree, for: "living-room")
            modes.save(.standard, for: "bedroom")
            let relaunched = RemoteModePreferences(defaults: defaults)
            #expect(relaunched.mode(for: "living-room") == .eyesFree)
            #expect(relaunched.mode(for: "bedroom") == .standard)
            #expect(relaunched.mode(for: "another-tv") == .standard)
        }
    }

    @Test func unsupportedModeFallsBackWithoutOverwritingThePreference() {
        withPreferences { modes, _ in
            modes.save(.eyesFree, for: "tv")
            #expect(modes.mode(for: "tv", available: [.standard]) == .standard)
            #expect(modes.mode(for: "tv") == .eyesFree)
        }
    }

    @Test func aTVMovingToANewAddressKeepsItsMode() {
        withPreferences { modes, _ in
            modes.save(.eyesFree, for: "lg@old-ip")
            modes.save(.eyesFree, for: "another-tv")
            modes.move(from: "lg@old-ip", to: "lg@new-ip")
            #expect(modes.mode(for: "lg@new-ip") == .eyesFree)
            #expect(modes.mode(for: "lg@old-ip") == .standard)
            #expect(modes.mode(for: "another-tv") == .eyesFree)
        }
    }

    @Test func forgettingOneTVPreservesTheOthers() {
        withPreferences { modes, _ in
            modes.save(.eyesFree, for: "a")
            modes.save(.eyesFree, for: "b")
            modes.forget("a")
            #expect(modes.mode(for: "a") == .standard)
            #expect(modes.mode(for: "b") == .eyesFree)
        }
    }

    @Test func legacySelectionMigratesOnlyToTheSelectedTV() {
        withPreferences { modes, defaults in
            defaults.set(true, forKey: "remoteView.eyesFree.v1")
            modes.migrateLegacy(for: nil)
            #expect(defaults.object(forKey: "remoteView.eyesFree.v1") != nil)
            modes.migrateLegacy(for: "selected")
            modes.migrateLegacy(for: "another")
            #expect(modes.mode(for: "selected") == .eyesFree)
            #expect(modes.mode(for: "another") == .standard)
            #expect(defaults.object(forKey: "remoteView.eyesFree.v1") == nil)
        }
    }

    @Test func migrationPreservesAnExplicitModeChoice() {
        withPreferences { modes, defaults in
            defaults.set(true, forKey: "remoteView.eyesFree.v1")
            modes.save(.standard, for: "selected")
            modes.migrateLegacy(for: "selected")
            #expect(modes.mode(for: "selected") == .standard)
        }
    }

    @Test func keyboardAndNumberPadArePersistentModes() {
        withPreferences { modes, defaults in
            modes.save(.keyboard, for: "office")
            modes.save(.keypad, for: "bedroom")
            let restored = RemoteModePreferences(defaults: defaults)
            #expect(restored.mode(for: "office") == .keyboard)
            #expect(restored.mode(for: "bedroom") == .keypad)
        }
    }

    @Test func legacyPadSelectionMigratesOnceWithoutChangingOtherTVs() {
        withPreferences { modes, defaults in
            defaults.set("keyboard", forKey: "padMode")
            modes.migrateLegacy(for: "selected")
            modes.migrateLegacy(for: "another")
            #expect(modes.mode(for: "selected") == .keyboard)
            #expect(modes.mode(for: "another") == .standard)
        }
    }

    @Test func unknownSavedModesAndMissingTVAreSafe() {
        withPreferences { modes, defaults in
            defaults.set(["tv": "future-mode"], forKey: "remoteView.modes.v1")
            modes.save(.eyesFree, for: nil)
            #expect(modes.mode(for: "tv") == .standard)
            #expect(modes.mode(for: nil) == .standard)
        }
    }
}
