/// Shared devices carry addresses and names; pairing and control modes stay local.
@MainActor
enum TVDeviceSync {
    static func merge(_ shared: [TVDevice], preserving local: [TVDevice],
                      modes: RemoteModePreferences) -> [TVDevice] {
        shared.map { tv in
            guard let previous = local.first(where: { $0.id == tv.id })
                ?? local.first(where: { $0.brand == tv.brand && $0.name == tv.name }) else { return tv }
            modes.move(from: previous.id, to: tv.id)
            var tv = tv
            tv.token = previous.token
            tv.isPaired = previous.isPaired
            tv.macAddress = tv.macAddress ?? previous.macAddress
            return tv
        }
    }
}
