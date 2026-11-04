import Foundation
import Testing
@testable import JoystickCore

@Suite("Synced TV mode preferences")
@MainActor
struct TVDeviceSyncTests {
    private func withPreferences(_ test: (RemoteModePreferences, UserDefaults) -> Void) {
        let name = "TVDeviceSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(RemoteModePreferences(defaults: defaults), defaults)
    }

    @Test func anUnselectedTVMovingKeepsItsMode() {
        withPreferences { modes, _ in
            let selected = TVDevice(name: "Selected", brand: .roku, host: "192.0.2.10")
            let other = TVDevice(name: "Other", brand: .lg, host: "192.0.2.20")
            var moved = other
            moved.host = "192.0.2.21"
            modes.save(.keypad, for: selected.id)
            modes.save(.eyesFree, for: other.id)
            let adopted = TVDeviceSync.merge([selected, moved], preserving: [selected, other], modes: modes)
            #expect(adopted.map(\.id) == [selected.id, moved.id])
            #expect(modes.mode(for: selected.id) == .keypad)
            #expect(modes.mode(for: moved.id) == .eyesFree)
            #expect(modes.mode(for: other.id) == .standard)
        }
    }

    @Test func everyMovedTVKeepsItsModeAcrossRelaunch() {
        withPreferences { modes, defaults in
            let a = TVDevice(name: "A", brand: .lg, host: "192.0.2.10")
            let b = TVDevice(name: "B", brand: .samsung, host: "192.0.2.20")
            var newA = a; newA.host = "192.0.2.11"
            var newB = b; newB.host = "192.0.2.21"
            modes.save(.keyboard, for: a.id)
            modes.save(.keypad, for: b.id)
            _ = TVDeviceSync.merge([newA, newB], preserving: [a, b], modes: modes)
            let restored = RemoteModePreferences(defaults: defaults)
            #expect(restored.mode(for: newA.id) == .keyboard)
            #expect(restored.mode(for: newB.id) == .keypad)
        }
    }

    @Test func syncPreservesLocalCredentialsAndMACFallback() {
        withPreferences { modes, _ in
            let lg = TVDevice(name: "LG", brand: .lg, host: "192.0.2.10", token: "local-test-token",
                              macAddress: "02:00:00:00:00:10")
            let android = TVDevice(name: "Android", brand: .androidTV, host: "192.0.2.20", isPaired: true)
            var movedLG = lg.withoutCredentials; movedLG.host = "192.0.2.11"; movedLG.macAddress = nil
            var movedAndroid = android.withoutCredentials; movedAndroid.host = "192.0.2.21"
            let adopted = TVDeviceSync.merge([movedLG, movedAndroid], preserving: [lg, android], modes: modes)
            #expect(adopted[0].token == "local-test-token")
            #expect(adopted[0].macAddress == lg.macAddress)
            #expect(adopted[1].isPaired)
        }
    }

    @Test func unmatchedTVsDoNotTakeOtherModesOrCredentials() {
        withPreferences { modes, _ in
            let local = TVDevice(name: "Room", brand: .lg, host: "192.0.2.10", token: "local-test-token")
            let differentBrand = TVDevice(name: "Room", brand: .roku, host: "192.0.2.20")
            let differentName = TVDevice(name: "Another room", brand: .lg, host: "192.0.2.30")
            modes.save(.eyesFree, for: local.id)
            let adopted = TVDeviceSync.merge([differentBrand, differentName], preserving: [local], modes: modes)
            #expect(adopted.allSatisfy { $0.token == nil })
            #expect(modes.mode(for: differentBrand.id) == .standard)
            #expect(modes.mode(for: differentName.id) == .standard)
            #expect(modes.mode(for: local.id) == .eyesFree)
        }
    }

    @Test func renamingAtTheSameAddressKeepsTheMode() {
        withPreferences { modes, _ in
            let local = TVDevice(name: "Old name", brand: .lg, host: "192.0.2.10", token: "local-test-token")
            var renamed = local.withoutCredentials; renamed.name = "New name"
            modes.save(.keyboard, for: local.id)
            let adopted = TVDeviceSync.merge([renamed], preserving: [local], modes: modes)
            #expect(adopted[0].name == "New name")
            #expect(adopted[0].token == local.token)
            #expect(modes.mode(for: renamed.id) == .keyboard)
        }
    }

    @Test func repeatedSyncPreservesLaterChoicesAndUnrelatedModes() {
        withPreferences { modes, _ in
            let local = TVDevice(name: "Room", brand: .lg, host: "192.0.2.10")
            var moved = local; moved.host = "192.0.2.11"
            modes.save(.eyesFree, for: local.id)
            modes.save(.keyboard, for: "unrelated-tv")
            let adopted = TVDeviceSync.merge([moved], preserving: [local], modes: modes)
            modes.save(.keypad, for: moved.id)
            _ = TVDeviceSync.merge([moved], preserving: adopted, modes: modes)
            #expect(modes.mode(for: moved.id) == .keypad)
            #expect(modes.mode(for: "unrelated-tv") == .keyboard)
            #expect(modes.mode(for: local.id) == .standard)
        }
    }
}
