import Foundation
import Testing
@testable import JoystickCore

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    #expect(condition())
}

@Suite("Interactive transport ordering and recovery", .serialized)
@MainActor
struct RemoteDriverTests {
    @Test func rokuDisconnectInvalidatesEveryQueuedNormalCommandAndOldResponse() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        driver.send(.down)
        driver.send(.left)
        driver.disconnect()
        LocalHTTP.complete("/keypress/Up")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(LocalHTTP.started == ["/keypress/Up"])
        #expect(driver.state == .idle)
        LocalHTTP.reset()
    }

    private func connectedRoku() async -> RokuDriver {
        LocalHTTP.reset()
        let driver = RokuDriver(device: TVDevice(name: "Test Roku", brand: .roku, host: "192.0.2.10"))
        driver.connect()
        await waitUntil { driver.state == .connected }
        return driver
    }

    @Test func rokuReportsTimeoutAfterDirectionalLift() async {
        let driver = await connectedRoku()
        let sender = JoystickSender(send: { key, request in
            await driver.sendInteractive(key, request: request)
        })
        sender.hold(.right)
        await waitUntil { LocalHTTP.started == ["/keypress/Right"] }
        sender.release()
        LocalHTTP.complete("/keypress/Right", status: nil)
        await waitUntil { if case .failed = driver.state { return true }; return false }
        #expect(driver.state == .failed("Couldn't reach the Roku."))
        #expect(LocalHTTP.started == ["/keypress/Right"])
        sender.stop()
        driver.disconnect()
    }

    @Test func rokuReportsAccessDeniedAfterDirectionalLift() async {
        let driver = await connectedRoku()
        let sender = JoystickSender(send: { key, request in
            await driver.sendInteractive(key, request: request)
        })
        sender.hold(.right)
        await waitUntil { LocalHTTP.started == ["/keypress/Right"] }
        sender.release()
        LocalHTTP.complete("/keypress/Right", status: 403)
        await waitUntil { if case .failed = driver.state { return true }; return false }
        if case .failed(let message) = driver.state {
            #expect(message.contains("blocking remote apps"))
        } else { Issue.record("The current connection failure was hidden by input cancellation") }
        sender.stop()
        driver.disconnect()
    }

    @Test func rokuIgnoresOldFailureAfterAReplacementConnection() async {
        let driver = await connectedRoku()
        let request = RemoteInputRequest()
        let operation = Task { await driver.sendInteractive(.right, request: request) }
        await waitUntil { LocalHTTP.started.count == 1 }
        driver.connect()
        await waitUntil { driver.state == .connected }
        LocalHTTP.complete("/keypress/Right", status: nil)
        await operation.value
        #expect(driver.state == .connected)
        driver.disconnect()
    }

    @Test func rokuDoesNotReportLocalTaskCancellationAsATVFailure() async {
        let driver = await connectedRoku()
        let operation = Task { await driver.sendInteractive(.right, request: RemoteInputRequest()) }
        await waitUntil { LocalHTTP.started.count == 1 }
        operation.cancel()
        LocalHTTP.complete("/keypress/Right", status: nil)
        await operation.value
        #expect(driver.state == .connected)
        driver.disconnect()
    }

    @Test func rokuNormalAndInteractiveCommandsShareTheirOrder() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        driver.send(.down)
        let request = RemoteInputRequest()
        let interactive = Task { await driver.sendInteractive(.back, request: request) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(LocalHTTP.started == ["/keypress/Up"])
        LocalHTTP.complete("/keypress/Up")
        await waitUntil { LocalHTTP.started.count == 2 }
        #expect(LocalHTTP.started.last == "/keypress/Down")
        LocalHTTP.complete("/keypress/Down")
        await waitUntil { LocalHTTP.started.count == 3 }
        #expect(LocalHTTP.started == ["/keypress/Up", "/keypress/Down", "/keypress/Back"])
        LocalHTTP.complete("/keypress/Back")
        await interactive.value
        #expect(LocalHTTP.completions.isEmpty)
    }

    @Test func rokuDropsReleasedJoystickInputWaitingBehindNormalCommands() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        let request = RemoteInputRequest()
        let interactive = Task { await driver.sendInteractive(.right, request: request) }
        try? await Task.sleep(for: .milliseconds(20))
        request.cancel()
        LocalHTTP.complete("/keypress/Up")
        await interactive.value
        #expect(LocalHTTP.started == ["/keypress/Up"])
        #expect(driver.state == .connected)
    }

    @Test func rokuAllowsTheNextNormalCommandAfterDiscardingStaleInput() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        let request = RemoteInputRequest()
        let interactive = Task { await driver.sendInteractive(.right, request: request) }
        try? await Task.sleep(for: .milliseconds(20))
        driver.send(.back)
        request.cancel()
        LocalHTTP.complete("/keypress/Up")
        await interactive.value
        await waitUntil { LocalHTTP.started.count == 2 }
        #expect(LocalHTTP.started == ["/keypress/Up", "/keypress/Back"])
        LocalHTTP.complete("/keypress/Back")
        await waitUntil { LocalHTTP.completions.isEmpty }
    }

    @Test func acceptedOKSurvivesLiftWhileStaleRokuMovementIsDiscarded() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        let sender = JoystickSender(send: { key, request in
            await driver.sendInteractive(key, request: request)
        })
        sender.hold(.right)
        try? await Task.sleep(for: .milliseconds(20))
        sender.release()
        sender.press(.select)
        sender.release()
        LocalHTTP.complete("/keypress/Up")
        await waitUntil { LocalHTTP.started.count == 2 }
        #expect(LocalHTTP.started == ["/keypress/Up", "/keypress/Select"])
        LocalHTTP.complete("/keypress/Select")
        await waitUntil { LocalHTTP.completions.isEmpty }
        sender.stop()
    }

    @Test func rokuRetainsActiveOKWhenTheNextGestureBegins() async {
        let driver = await connectedRoku()
        driver.send(.up)
        await waitUntil { LocalHTTP.started.count == 1 }
        var accepted: RemoteInputRequest?
        let sender = JoystickSender(send: { key, request in
            if key == .select { accepted = request }
            await driver.sendInteractive(key, request: request)
        })
        sender.press(.select)
        sender.release()
        await waitUntil { accepted != nil }
        sender.hold(.right)
        #expect(accepted?.isCancelled == false)
        LocalHTTP.complete("/keypress/Up")
        await waitUntil { LocalHTTP.started.count == 2 }
        #expect(LocalHTTP.started == ["/keypress/Up", "/keypress/Select"])
        LocalHTTP.complete("/keypress/Select")
        await waitUntil { LocalHTTP.started.count == 3 }
        #expect(LocalHTTP.started == ["/keypress/Up", "/keypress/Select", "/keypress/Right"])
        sender.release()
        LocalHTTP.complete("/keypress/Right")
        await waitUntil { LocalHTTP.completions.isEmpty }
        sender.stop()
    }

    @Test func cancelledRokuResponseCannotRestoreDisconnectedState() async {
        let driver = await connectedRoku()
        let request = RemoteInputRequest()
        let interactive = Task { await driver.sendInteractive(.right, request: request) }
        await waitUntil { LocalHTTP.started.count == 1 }
        request.cancel()
        driver.disconnect()
        LocalHTTP.complete("/keypress/Right")
        await interactive.value
        #expect(driver.state == .idle)
    }

    private func connectLG() -> (LGDriver, LocalWebSocket, LocalWebSocket) {
        LocalWebSocket.instances = []
        let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
        driver.connect()
        let control = LocalWebSocket.instances.last!
        control.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        respondToPointerRequest(control)
        return (driver, control, LocalWebSocket.instances.last!)
    }

    private func respondToPointerRequest(_ control: LocalWebSocket) {
        let request = JSON.parse(control.sent.last!)!
        let id = request["id"] as! String
        control.onText?("{\"id\":\"\(id)\",\"payload\":{\"socketPath\":\"ws://192.0.2.20/pointer\"}}")
    }

    @Test func deliberateCommandsReconnectAnIdleLGWithoutPairing() {
        for (key, name) in [(RemoteKey.up, "UP"), (.back, "BACK"), (.home, "HOME")] {
            let (driver, control, _) = connectLG()
            control.peerClosed()
            #expect(driver.state == .idle)
            let availability = RemoteInputAvailability(state: driver.state)
            #expect(availability.allowsCommands)
            #expect(!availability.allowsGestures)
            if availability.allowsCommands { driver.send(key) }
            let replacement = LocalWebSocket.instances.last!
            #expect(replacement !== control)
            #expect(driver.state == .connecting)
            let registration = replacement.sent.compactMap(JSON.parse).first!
            let payload = registration["payload"] as! [String: Any]
            #expect(payload["client-key"] as? String == "test")
            #expect(payload["forcePairing"] as? Bool == false)
            replacement.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
            respondToPointerRequest(replacement)
            #expect(driver.state == .connected)
            #expect(LocalWebSocket.instances.last!.sent == ["type:button\nname:\(name)\n\n"])
            driver.disconnect()
        }
    }

    @Test func lgRecoversInputSocketWithoutReplayingTheTriggeringKey() async {
        let (driver, control, pointer) = connectLG()
        await driver.sendInteractive(.right, request: RemoteInputRequest())
        #expect(pointer.sent == ["type:button\nname:RIGHT\n\n"])
        pointer.peerClosed()
        let before = control.sent.count
        let left = Task { await driver.sendInteractive(.left, request: RemoteInputRequest()) }
        await waitUntil { control.sent.count == before + 1 }
        #expect(driver.state == .connected)
        var upEntered = false
        let up = Task { upEntered = true; await driver.sendInteractive(.up, request: RemoteInputRequest()) }
        await waitUntil { upEntered }
        #expect(control.sent.count == before + 1) // One recovery request in flight.
        respondToPointerRequest(control)
        await left.value
        await up.value
        let replacement = LocalWebSocket.instances.last!
        #expect(replacement !== pointer)
        #expect(replacement.sent.isEmpty)
        await driver.sendInteractive(.select, request: RemoteInputRequest())
        #expect(replacement.sent == ["type:button\nname:ENTER\n\n"])
    }

    @Test func lgRetainsOneShotUntilPointerCreation() async {
        LocalWebSocket.instances = []
        let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
        driver.connect()
        let control = LocalWebSocket.instances.last!
        control.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        var entered = false
        let operation = Task { entered = true; await driver.sendInteractive(.select, request: RemoteInputRequest()) }
        await waitUntil { entered }
        respondToPointerRequest(control)
        let pointer = LocalWebSocket.instances.last!
        await operation.value
        #expect(pointer.sent == ["type:button\nname:ENTER\n\n"])
        driver.disconnect()
    }

    @Test func lgRetainsEachOneShotUntilPointerHandshake() async {
        LocalWebSocket.delayedOpenPaths = ["/pointer"]
        defer { LocalWebSocket.delayedOpenPaths = [] }
        for (key, name) in [(RemoteKey.select, "ENTER"), (.back, "BACK"), (.home, "HOME")] {
            let (driver, _, pointer) = connectLG()
            #expect(!pointer.isReady)
            var entered = false
            let operation = Task { entered = true; await driver.sendInteractive(key, request: RemoteInputRequest()) }
            await waitUntil { entered }
            #expect(pointer.sent.isEmpty)
            pointer.completeHandshake()
            await operation.value
            #expect(pointer.sent == ["type:button\nname:\(name)\n\n"])
            driver.disconnect()
        }
    }

    @Test func lgBoundsRecoveryRequestsWhenPointerServiceDeclines() async {
        for key in [RemoteKey.home, .right] {
            LocalWebSocket.instances = []
            let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
            driver.connect()
            let control = LocalWebSocket.instances.last!
            control.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
            let first = JSON.parse(control.sent.last!)!["id"] as! String
            control.onText?("{\"id\":\"\(first)\",\"payload\":{}}")
            let before = control.sent.count
            let request = RemoteInputRequest()
            var entered = false
            let operation = Task { entered = true; await driver.sendInteractive(key, request: request) }
            await waitUntil { entered && control.sent.count > before }
            var replied = Set<String>()
            let deadline = ContinuousClock.now + .milliseconds(160)
            while ContinuousClock.now < deadline {
                for text in control.sent.dropFirst(before) {
                    if let id = JSON.parse(text)?["id"] as? String, replied.insert(id).inserted {
                        control.onText?("{\"id\":\"\(id)\",\"payload\":{}}")
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            request.cancel()
            await operation.value
            #expect(control.sent.count == before + 1)
            #expect(driver.state == .connected) // Cancellation is quiet, not a timeout.
            driver.disconnect()
        }
    }

    @Test func lgMakesPointerTimeoutUnavailableAndPreservesCredentials() async {
        LocalWebSocket.delayedOpenPaths = ["/pointer"]
        defer { LocalWebSocket.delayedOpenPaths = [] }
        let (driver, control, pointer) = connectLG()
        await driver.sendInteractive(.home, request: RemoteInputRequest())
        #expect(driver.state == .idle) // No failed-address rediscovery for a pointer error.
        #expect(driver.device.token == "test")
        #expect(!control.isReady)
        #expect(!pointer.isReady)
        #expect(pointer.sent.isEmpty)
    }

    @Test func lgMissingPointerCreationTimesOutForDirection() async {
        LocalWebSocket.instances = []
        let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
        driver.connect()
        let control = LocalWebSocket.instances.last!
        control.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        let before = control.sent.count
        // No pointer descriptor arrives; direction-only input must still hit the bound.
        await driver.sendInteractive(.right, request: RemoteInputRequest())
        #expect(driver.state == .idle)
        #expect(driver.device.token == "test")
        #expect(!control.isReady)
        #expect(control.sent.count == before) // No duplicate acquisition requests.
        #expect(LocalWebSocket.instances.count == 1)
    }

    @Test func lgMissingPointerCancellationStaysQuietAndDoesNotReplayDirection() async {
        LocalWebSocket.instances = []
        let driver = LGDriver(device: TVDevice(name: "Test LG", brand: .lg, host: "192.0.2.20", token: "test"))
        driver.connect()
        let control = LocalWebSocket.instances.last!
        control.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        let before = control.sent.count
        let request = RemoteInputRequest()
        var entered = false
        let operation = Task { entered = true; await driver.sendInteractive(.right, request: request) }
        await waitUntil { entered }
        request.cancel() // Lift before the pointer descriptor or readiness deadline.
        await operation.value
        #expect(driver.state == .connected)
        #expect(driver.device.token == "test")
        #expect(control.sent.count == before)
        respondToPointerRequest(control)
        let pointer = LocalWebSocket.instances.last!
        #expect(pointer.sent.isEmpty)
        await driver.sendInteractive(.up, request: RemoteInputRequest())
        #expect(pointer.sent == ["type:button\nname:UP\n\n"])
        driver.disconnect()
    }

    @Test func lgDiscardsCancelledInputDuringHandshake() async {
        LocalWebSocket.delayedOpenPaths = ["/pointer"]
        defer { LocalWebSocket.delayedOpenPaths = [] }
        for key in [RemoteKey.select, .right] {
            let (driver, _, pointer) = connectLG()
            let request = RemoteInputRequest()
            var entered = false
            let operation = Task { entered = true; await driver.sendInteractive(key, request: request) }
            await waitUntil { entered }
            request.cancel() // Lifecycle stop for OK, ordinary lift for movement.
            pointer.completeHandshake()
            await operation.value
            #expect(pointer.sent.isEmpty)
            #expect(driver.state == .connected)
            driver.disconnect()
        }
    }

    @Test func lgDoesNotCarryOneShotIntoANewPrimarySession() async {
        LocalWebSocket.delayedOpenPaths = ["/pointer"]
        defer { LocalWebSocket.delayedOpenPaths = [] }
        let (driver, _, oldPointer) = connectLG()
        var entered = false
        let operation = Task { entered = true; await driver.sendInteractive(.home, request: RemoteInputRequest()) }
        await waitUntil { entered }
        driver.disconnect()
        driver.connect()
        let replacementControl = LocalWebSocket.instances.last!
        replacementControl.onText?("{\"type\":\"registered\",\"id\":\"register_0\",\"payload\":{}}")
        respondToPointerRequest(replacementControl)
        let replacementPointer = LocalWebSocket.instances.last!
        replacementPointer.completeHandshake()
        await operation.value
        #expect(oldPointer.sent.isEmpty)
        #expect(replacementPointer.sent.isEmpty)
        #expect(driver.state == .connected)
        driver.disconnect()
    }

    @Test func lgDoesNotRecoverOrSendCancelledInput() async {
        let (driver, control, pointer) = connectLG()
        pointer.peerClosed()
        let request = RemoteInputRequest()
        request.cancel()
        let before = control.sent.count
        await driver.sendInteractive(.back, request: request)
        #expect(control.sent.count == before)
        #expect(LocalWebSocket.instances.count == 2)
    }

    @Test func lgDoesNotPairOrReconnectFromDisconnectedInteractiveInput() async {
        let (driver, control, _) = connectLG()
        driver.disconnect()
        let before = control.sent.count
        await driver.sendInteractive(.home, request: RemoteInputRequest())
        #expect(control.sent.count == before)
        #expect(driver.state == .idle)
    }
}
