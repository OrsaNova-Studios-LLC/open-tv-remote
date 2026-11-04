import Testing
@testable import JoystickCore

@Suite("Remote input availability")
struct RemoteInputAvailabilityTests {
    private let states: [ConnectionState] = [
        .idle, .connecting, .unpaired, .pairing(.acceptOnTV), .connected, .failed("offline")
    ]

    @Test func deliberateCommandsCanReachDriverRecovery() {
        for state in states {
            #expect(RemoteInputAvailability(state: state).allowsCommands)
        }
    }

    @Test func gesturesRequireAnEstablishedConnection() {
        for state in states {
            #expect(RemoteInputAvailability(state: state).allowsGestures == (state == .connected))
        }
    }

    @Test func everySheetAndCombinationBlocksBothInputPaths() {
        for state in states {
            for mask in 1...15 {
                let availability = RemoteInputAvailability(state: state,
                    showingDevices: mask & 1 != 0, showingKeyboard: mask & 2 != 0,
                    showingApps: mask & 4 != 0, showingSettings: mask & 8 != 0)
                #expect(!availability.allowsCommands)
                #expect(!availability.allowsGestures)
            }
        }
    }
}
