import Foundation
import CoreGraphics
import Testing
@testable import JoystickCore

@Suite("Eyes-free gesture")
struct JoystickGestureTests {
    @Test func aBriefTapSelectsAndResets() {
        var input = JoystickGesture()
        input.update(start: CGPoint(x: 280, y: 500), location: CGPoint(x: 282, y: 503), time: 10)
        #expect(input.direction == nil)
        let selected = input.finish(time: 10.15)
        #expect(selected)
        #expect(input.origin == nil)
    }

    @Test func restingDoesNotSelect() {
        var input = JoystickGesture()
        input.update(start: .zero, location: .zero, time: 0)
        let selected = input.finish(time: 0.6)
        #expect(!selected)
    }

    @Test func aDragReturningToCenterNeverSelects() {
        var input = JoystickGesture()
        input.update(start: .zero, location: CGPoint(x: 45, y: 0), time: 0)
        #expect(input.direction == .right)
        input.update(start: .zero, location: .zero, time: 0.1)
        #expect(input.direction == nil)
        let selected = input.finish(time: 0.2)
        #expect(!selected)
    }

    @Test func everyContactReanchorsAllFourDirections() {
        for origin in [CGPoint(x: 40, y: 70), CGPoint(x: 280, y: 500)] {
            for (offset, key) in [(CGPoint(x: 40, y: 0), RemoteKey.right),
                                  (CGPoint(x: -40, y: 0), .left),
                                  (CGPoint(x: 0, y: -40), .up),
                                  (CGPoint(x: 0, y: 40), .down)] {
                var input = JoystickGesture()
                input.update(start: origin, location: CGPoint(x: origin.x + offset.x, y: origin.y + offset.y), time: 0)
                #expect(input.direction == key)
                let selected = input.finish(time: 0.1)
                #expect(!selected)
            }
        }
    }

    @Test func neutralZoneHasHysteresis() {
        var input = JoystickGesture()
        input.update(start: .zero, location: CGPoint(x: 20, y: 0), time: 0)
        #expect(input.direction == nil)
        input.update(start: .zero, location: CGPoint(x: 30, y: 0), time: 0.1)
        #expect(input.direction == .right)
        input.update(start: .zero, location: CGPoint(x: 20, y: 0), time: 0.2)
        #expect(input.direction == .right)
        input.update(start: .zero, location: CGPoint(x: 10, y: 0), time: 0.3)
        #expect(input.direction == nil)
    }

    @Test func diagonalJitterDoesNotChangeAxis() {
        var input = JoystickGesture()
        input.update(start: .zero, location: CGPoint(x: 40, y: 20), time: 0)
        input.update(start: .zero, location: CGPoint(x: 40, y: 45), time: 0.1)
        #expect(input.direction == .right)
        input.update(start: .zero, location: CGPoint(x: 25, y: 50), time: 0.2)
        #expect(input.direction == .down)
    }

    @Test func cancellationCannotBecomeSelection() {
        var input = JoystickGesture()
        input.update(start: .zero, location: .zero, time: 0)
        input.cancel()
        let selected = input.finish(location: .zero, time: 0.1)
        #expect(!selected)
    }

    @Test func finalReleaseMovementCannotBecomeATap() {
        var input = JoystickGesture()
        input.update(start: .zero, location: .zero, time: 0)
        let selected = input.finish(location: CGPoint(x: 40, y: 0), time: 0.1)
        #expect(!selected)
    }

    @Test func movementWithinNeutralZoneStillSuppressesAccidentalSelection() {
        var input = JoystickGesture()
        input.update(start: .zero, location: CGPoint(x: 18, y: 0), time: 0)
        #expect(input.direction == nil)
        let selected = input.finish(time: 0.1)
        #expect(!selected)
    }
}

@MainActor
private final class TransportGate {
    var keys: [RemoteKey] = []
    var requests: [RemoteInputRequest] = []
    var completions: [CheckedContinuation<Void, Never>] = []
    func send(_ key: RemoteKey, request: RemoteInputRequest) async {
        keys.append(key)
        requests.append(request)
        await withCheckedContinuation { completions.append($0) }
    }
    func complete() {
        if !completions.isEmpty { completions.removeFirst().resume() }
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    #expect(condition())
}

@Suite("Eyes-free sending", .serialized)
@MainActor
struct JoystickSenderTests {
    @Test func firmEngagementAndRegularHoldPulsesFollowNewCommands() async {
        var time: TimeInterval = 0
        var pulses: [(TimeInterval, RemoteInputRequest.Feedback)] = []
        var count = 0
        let sender = JoystickSender(send: { _, request in
            count += 1
            if request.feedback != .none { pulses.append((time, request.feedback)) }
        }, sleep: { delay in
            time += delay == .milliseconds(420) ? 0.42 : 0.18
        }, now: { time })
        sender.hold(.right)
        await eventually { count == 41 }
        #expect(pulses.first?.1 == .firm)
        #expect(pulses.count > 2 && pulses.count < 15)
        #expect(pulses.dropFirst().allSatisfy { $0.1 == .soft })
        for (first, second) in zip(pulses, pulses.dropFirst()) {
            // With no transport delay, pulses stay within the intended cadence.
            #expect(second.0 - first.0 >= 0.5)
            #expect(second.0 - first.0 <= 0.61)
        }
        sender.stop()
    }

    @Test func stalledTransportDoesNotProduceAnIndependentHapticHeartbeat() async {
        let gate = TransportGate()
        var time: TimeInterval = 0
        let sender = JoystickSender(send: gate.send, now: { time })
        sender.hold(.right)
        await eventually { gate.requests.count == 1 }
        time = 10
        try? await Task.sleep(for: .milliseconds(30))
        #expect(gate.requests.count == 1)
        #expect(gate.requests[0].feedback == .firm)
        sender.release()
        gate.complete()
        try? await Task.sleep(for: .milliseconds(25))
        #expect(gate.requests.count == 1)
    }

    @Test func directionChangeGetsFirmFeedbackWithinTheRepeatCooldown() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send, now: { 0 })
        sender.hold(.right)
        await eventually { gate.requests.count == 1 }
        sender.hold(.down)
        gate.complete()
        await eventually { gate.requests.count == 2 }
        #expect(gate.requests[0].feedback == .firm)
        #expect(gate.requests[1].feedback == .firm)
        sender.stop()
        gate.complete()
    }

    @Test func liftingDuringSlowTransportDiscardsAllRepeats() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send)
        sender.hold(.right)
        await eventually { gate.keys.count == 1 }
        sender.stop()
        gate.complete()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(gate.keys == [.right])
    }

    @Test func onlyLatestDirectionSurvivesSlowTransport() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send)
        sender.hold(.up)
        await eventually { gate.keys.count == 1 }
        sender.hold(.right)
        sender.hold(.left)
        #expect(gate.keys == [.up])
        gate.complete()
        await eventually { gate.keys.count == 2 }
        #expect(gate.keys == [.up, .left])
        sender.stop()
        gate.complete()
    }

    @Test func backReplacesQueuedMovementWithoutRepeating() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send)
        sender.hold(.right)
        await eventually { gate.keys.count == 1 }
        sender.hold(.down)
        sender.press(.back)
        gate.complete()
        await eventually { gate.keys.count == 2 }
        #expect(gate.keys == [.right, .back])
        gate.complete()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(gate.keys.count == 2)
    }

    @Test func nextContactKeepsAcceptedBackAheadOfMovement() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send)
        sender.hold(.down)
        await eventually { gate.keys.count == 1 }
        sender.press(.back)
        sender.release()
        sender.hold(.right)
        gate.complete()
        await eventually { gate.keys.count == 2 }
        #expect(gate.keys == [.down, .back])
        gate.complete()
        await eventually { gate.keys.count == 3 }
        #expect(gate.keys == [.down, .back, .right])
        sender.release()
        gate.complete()
        sender.stop()
    }

    @Test func deliberatePressesKeepTheirOrderBehindSlowMovement() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send)
        sender.hold(.down)
        await eventually { gate.keys.count == 1 }
        sender.press(.back)
        sender.release()
        sender.press(.home)
        sender.release()
        gate.complete()
        await eventually { gate.keys.count == 2 }
        #expect(gate.keys == [.down, .back])
        gate.complete()
        await eventually { gate.keys.count == 3 }
        #expect(gate.keys == [.down, .back, .home])
        gate.complete()
        sender.stop()
    }

    @Test func selectionIsAlwaysOneCommand() async {
        var keys: [RemoteKey] = []
        let sender = JoystickSender(send: { key, _ in keys.append(key) }, sleep: { _ in })
        sender.press(.select)
        await eventually { keys.count == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(keys == [.select])
    }

    @Test func stopDuringRepeatDelayDoesNotSendAgain() async {
        var keys: [RemoteKey] = []
        let sender = JoystickSender(send: { key, _ in keys.append(key) })
        sender.hold(.down)
        await eventually { keys.count == 1 }
        sender.stop()
        try? await Task.sleep(for: .milliseconds(460))
        #expect(keys == [.down])
    }

    @Test func liftPreservesOKBehindSlowMovement() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send)
        sender.hold(.right)
        await eventually { gate.keys.count == 1 }
        sender.release()
        #expect(gate.requests[0].isCancelled)
        sender.press(.select)
        sender.release() // GestureState resets after onEnded queued OK.
        gate.complete()
        await eventually { gate.keys.count == 2 }
        #expect(gate.keys == [.right, .select])
        #expect(!gate.requests[1].isCancelled)
        gate.complete()
        sender.stop()
    }

    @Test func liftPreservesBackPressedWhileThumbWasDown() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send)
        sender.hold(.right)
        await eventually { gate.keys.count == 1 }
        sender.press(.back)
        sender.release()
        sender.release() // Both onEnded and the touch-reset observer can run.
        gate.complete()
        await eventually { gate.keys.count == 2 }
        #expect(gate.keys == [.right, .back])
        #expect(!gate.requests[1].isCancelled)
        gate.complete()
        sender.stop()
    }

    @Test func immediateTapSurvivesTouchResetBeforeWorkerStarts() async {
        var keys: [RemoteKey] = []
        let sender = JoystickSender(send: { key, _ in keys.append(key) })
        sender.press(.select)
        sender.release()
        await eventually { keys.count == 1 }
        #expect(keys == [.select])
        sender.stop()
    }

    @Test func lifecycleCancellationStillDropsPendingOK() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send)
        sender.hold(.up)
        await eventually { gate.keys.count == 1 }
        sender.press(.select)
        sender.press(.back)
        sender.stop() // Dismissal/background/session change invalidates every queued press.
        gate.complete()
        try? await Task.sleep(for: .milliseconds(25))
        #expect(gate.keys == [.up])
    }

    @Test func liftingBeforeDispatchDropsMovement() async {
        var keys: [RemoteKey] = []
        let sender = JoystickSender(send: { key, _ in keys.append(key) })
        sender.hold(.down)
        sender.release()
        try? await Task.sleep(for: .milliseconds(25))
        #expect(keys.isEmpty)
    }

    @Test func repeatsHaveAnInitialDelayAndAHardLimit() async {
        var keys: [RemoteKey] = []
        var delays: [Duration] = []
        var feedbackKeys: [RemoteKey] = []
        let sender = JoystickSender(send: { key, request in
            keys.append(key)
            if !request.isRepeat { feedbackKeys.append(key) }
        }, sleep: { delays.append($0) })
        sender.hold(.left)
        await eventually { keys.count == 41 }
        #expect(delays.first == .milliseconds(420))
        #expect(delays.dropFirst().allSatisfy { $0 == .milliseconds(180) })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(keys.count == 41)
        #expect(feedbackKeys == [.left])
        sender.stop()
    }

    @Test func directionChangesAndNewContactsRestoreFeedbackAfterRepeating() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send, sleep: { _ in })
        sender.hold(.right)
        await eventually { gate.keys.count == 1 }
        #expect(!gate.requests[0].isRepeat)
        gate.complete()
        await eventually { gate.keys.count == 2 }
        #expect(gate.requests[1].isRepeat)

        sender.hold(.down)
        gate.complete()
        await eventually { gate.keys.count == 3 }
        #expect(gate.keys.last == .down)
        #expect(!gate.requests[2].isRepeat)
        gate.complete()
        await eventually { gate.keys.count == 4 }
        #expect(gate.requests[3].isRepeat)

        sender.release()
        sender.hold(.down)
        gate.complete()
        await eventually { gate.keys.count == 5 }
        #expect(gate.keys.last == .down)
        #expect(!gate.requests[4].isRepeat)
        sender.stop()
        gate.complete()
    }

    @Test func deliberatePressesKeepFeedbackAfterHeldRepeats() async {
        let gate = TransportGate()
        let sender = JoystickSender(send: gate.send, sleep: { _ in })
        sender.hold(.up)
        await eventually { gate.keys.count == 1 }
        gate.complete()
        await eventually { gate.keys.count == 2 }
        #expect(gate.requests[1].isRepeat)

        for (index, key) in [RemoteKey.select, .back, .home].enumerated() {
            sender.press(key)
            gate.complete()
            await eventually { gate.keys.count == index + 3 }
            #expect(gate.keys.last == key)
            #expect(!gate.requests[index + 2].isRepeat)
        }
        sender.stop()
        gate.complete()
    }
}
