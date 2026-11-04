import Foundation
import CoreGraphics

/// Relative input: every contact gets its own center. Returning to center pauses;
/// only a brief contact that never travelled becomes an OK press.
struct JoystickGesture {
    private(set) var origin: CGPoint?
    private(set) var offset: CGSize = .zero
    private(set) var direction: RemoteKey?
    private var startedAt: TimeInterval = 0
    private var maximumTravel: CGFloat = 0

    mutating func update(start: CGPoint, location: CGPoint, time: TimeInterval) {
        if origin == nil {
            origin = start
            startedAt = time
            maximumTravel = 0
        }
        guard let origin else { return }
        offset = CGSize(width: location.x - origin.x, height: location.y - origin.y)
        let distance = hypot(offset.width, offset.height)
        maximumTravel = max(maximumTravel, distance)
        // A smaller release threshold prevents jitter at the edge of the neutral zone.
        guard distance >= (direction == nil ? 24 : 16) else {
            direction = nil
            return
        }
        let x = offset.width, y = offset.height
        let horizontal: Bool
        switch direction {
        case .left?, .right?: horizontal = abs(y) <= abs(x) * 1.35
        case .up?, .down?: horizontal = abs(x) > abs(y) * 1.35
        default: horizontal = abs(x) > abs(y)
        }
        direction = horizontal ? (x < 0 ? .left : .right) : (y < 0 ? .up : .down)
    }

    mutating func finish(location: CGPoint? = nil, time: TimeInterval) -> Bool {
        if let location, let origin { update(start: origin, location: location, time: time) }
        let select = origin != nil && maximumTravel <= 10 && time - startedAt <= 0.28
        cancel()
        return select
    }

    mutating func cancel() {
        origin = nil
        offset = .zero
        direction = nil
        maximumTravel = 0
    }
}

/// Cancellation belongs to the input, not the connection. A driver waiting for
/// its turn can discard stale input without cancelling a shared WebSocket.
@MainActor
final class RemoteInputRequest {
    enum Feedback { case firm, soft, none }
    let isRepeat: Bool
    let feedback: Feedback
    private(set) var isCancelled = false

    init(isRepeat: Bool = false, feedback: Feedback = .firm) {
        self.isRepeat = isRepeat
        self.feedback = feedback
    }
    func cancel() { isCancelled = true }
}

/// One transport operation at a time. Deliberate presses keep their order;
/// only pending movement is replaceable, so a slow TV cannot build a repeat tail.
/// Already transmitted input cannot be recalled.
@MainActor
final class JoystickSender {
    private enum Command {
        case direction(RemoteKey, isRepeat: Bool), press(RemoteKey)
        var key: RemoteKey {
            switch self { case .direction(let key, _), .press(let key): return key }
        }
        var repeats: Bool {
            if case .direction = self { return true }
            return false
        }
        var isRepeat: Bool {
            if case .direction(_, let isRepeat) = self { return isRepeat }
            return false
        }
    }

    private let send: (RemoteKey, RemoteInputRequest) async -> Void
    private let sleep: (Duration) async throws -> Void
    private let now: () -> TimeInterval
    private var lastFeedback: TimeInterval?
    private var pending: [Command] = []
    private var active: (request: RemoteInputRequest, repeats: Bool)?
    private var held: RemoteKey?
    private var generation = 0
    private var repeats = 0
    private var worker: Task<Void, Never>?
    private var pause: Task<Void, Error>?

    init(send: @escaping (RemoteKey, RemoteInputRequest) async -> Void,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.send = send
        self.sleep = sleep
        self.now = now
    }

    func hold(_ direction: RemoteKey?) {
        guard direction != held else { return }
        release()
        held = direction
        if let direction { pending.append(.direction(direction, isRepeat: false)) }
        start()
    }

    func press(_ key: RemoteKey) {
        release()
        pending.append(.press(key))
        start()
    }

    /// Normal lift stops movement but preserves an explicitly accepted OK/Back/Home.
    func release() { reset(cancelPresses: false) }

    /// Dismissal, backgrounding or a session change invalidates every pending input.
    func stop() { reset(cancelPresses: true) }

    private func reset(cancelPresses: Bool) {
        generation += 1
        held = nil
        if cancelPresses { pending.removeAll() }
        else { pending.removeAll { $0.repeats } }
        if cancelPresses || active?.repeats == true { active?.request.cancel() }
        repeats = 0
        lastFeedback = nil
        pause?.cancel()
    }

    private func start() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { @MainActor [weak self] in await self?.run() }
    }

    private func run() async {
        defer { worker = nil }
        while !pending.isEmpty {
            let command = pending.removeFirst()
            let token = generation
            let time = now()
            let feedback: RemoteInputRequest.Feedback
            if !command.isRepeat {
                feedback = .firm
            } else if let lastFeedback, time - lastFeedback >= 0.5 {
                feedback = .soft
            } else {
                feedback = .none
            }
            if feedback != .none { lastFeedback = time }
            let request = RemoteInputRequest(isRepeat: command.isRepeat, feedback: feedback)
            active = (request, command.repeats)
            await send(command.key, request)
            active = nil
            guard token == generation, command.repeats, held == command.key, repeats < 40 else { continue }
            let delay: Duration = repeats == 0 ? .milliseconds(420) : .milliseconds(180)
            let sleep = self.sleep
            let wait = Task { @MainActor in try await sleep(delay) }
            pause = wait
            do { try await wait.value } catch { }
            pause = nil
            guard token == generation, held == command.key else { continue }
            repeats += 1
            pending.append(.direction(command.key, isRepeat: true))
        }
    }
}
