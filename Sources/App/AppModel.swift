import Foundation
import Observation

@MainActor
@Observable
final class AppModel: TVDriverDelegate {
    private(set) var devices: [TVDevice] = DeviceStore.load()
    private(set) var currentID: String? = DeviceStore.currentID
    private(set) var state: ConnectionState = .idle
    private(set) var installedApps: [TVApp]?
    /// True while we search the network for a saved TV that stopped answering at its old address.
    private(set) var isRelocating = false

    var showingDevices = false
    var showingKeyboard = false
    var showingApps = false
    var showingSettings = false
    private(set) var remoteControlMode: RemoteControlMode = .standard
    private let remoteModes = RemoteModePreferences()

    var remoteInputAvailable: Bool {
        inputAvailability.allowsGestures
    }

    var remoteCommandsAvailable: Bool {
        inputAvailability.allowsCommands
    }

    private var inputAvailability: RemoteInputAvailability {
        RemoteInputAvailability(state: state, showingDevices: showingDevices,
                                showingKeyboard: showingKeyboard, showingApps: showingApps,
                                showingSettings: showingSettings)
    }

    var availableRemoteModes: [RemoteControlMode] { RemoteControlMode.allCases }

    func selectRemoteMode(_ mode: RemoteControlMode) {
        remoteControlMode = mode
        #if DEBUG
        if DemoMode.isEnabled { return }
        #endif
        remoteModes.save(mode, for: currentID)
    }

    let discovery = Discovery()
    let jellyfin = JellyfinStore()

    @ObservationIgnored private var driver: TVDriver?
    @ObservationIgnored private var relocateTask: Task<Void, Never>?
    @ObservationIgnored private var relocationAttempted = false

    var current: TVDevice? { devices.first { $0.id == currentID } }

    init() {
        #if DEBUG
        if DemoMode.isEnabled {
            devices = DemoMode.devices
            currentID = DemoMode.devices[0].id
            let driver = DemoDriver(device: DemoMode.devices[0])
            driver.delegate = self
            self.driver = driver
            state = .connected
            if UserDefaults.standard.bool(forKey: "demoEyesFree") { remoteControlMode = .eyesFree }
            else if let raw = UserDefaults.standard.string(forKey: "padMode"),
                    let mode = RemoteControlMode(rawValue: raw) { remoteControlMode = mode }
            switch DemoMode.sheet {
            case "apps": showingApps = true
            case "devices": showingDevices = true
            case "keyboard": showingKeyboard = true
            case "settings": showingSettings = true
            default: break
            }
            return
        }
        #endif
        NotificationCenter.default.addObserver(forName: CloudSettings.didChange, object: nil, queue: .main) { [weak self] note in
            let keys = note.userInfo?["keys"] as? [String] ?? []
            MainActor.assumeIsolated { self?.settingsChanged(keys) }
        }
        CloudSettings.start()
        if let current {
            activate(current)
        }
    }

    // MARK: Sync

    private func settingsChanged(_ keys: [String]) {
        if keys.contains(CloudSettings.devices) { adoptSharedDevices() }
        if keys.contains(CloudSettings.appChoices) { appChoices = Self.loadAppChoices() }
        jellyfin.settingsChanged(keys)
    }

    /// Takes the TV list from the user's other devices, keeping this device's pairing for each TV.
    /// A TV that moved to a new address elsewhere is matched by name, so it stays paired here.
    private func adoptSharedDevices() {
        guard let shared = DeviceStore.loadShared() else { return }
        let mine = devices
        let previous = current
        devices = TVDeviceSync.merge(shared, preserving: mine, modes: remoteModes)
        DeviceStore.save(devices)
        guard let previous, current == nil else { return }
        if let moved = devices.first(where: { $0.brand == previous.brand && $0.name == previous.name }) {
            activate(moved)
        } else {
            forget(previous)
        }
    }

    // MARK: Devices

    func select(_ device: TVDevice) {
        if !devices.contains(where: { $0.id == device.id }) {
            devices.append(device)
            DeviceStore.save(devices)
        }
        activate(devices.first { $0.id == device.id } ?? device)
    }

    func forget(_ device: TVDevice) {
        remoteModes.forget(device.id)
        devices.removeAll { $0.id == device.id }
        DeviceStore.save(devices)
        if device.id == currentID {
            driver?.disconnect()
            driver = nil
            currentID = nil
            remoteControlMode = .standard
            DeviceStore.currentID = nil
            state = .idle
            installedApps = nil
        }
    }

    private func activate(_ device: TVDevice) {
        driver?.disconnect()
        relocateTask?.cancel()
        relocateTask = nil
        isRelocating = false
        relocationAttempted = false
        currentID = device.id
        DeviceStore.currentID = device.id
        installedApps = nil
        let driver = Self.makeDriver(device)
        driver.delegate = self
        self.driver = driver
        state = driver.state
        remoteModes.migrateLegacy(for: device.id)
        remoteControlMode = remoteModes.mode(for: device.id)
        driver.connect()
    }

    private static func makeDriver(_ device: TVDevice) -> TVDriver {
        switch device.brand {
        case .androidTV: AndroidTVDriver(device: device)
        case .roku: RokuDriver(device: device)
        case .samsung: SamsungDriver(device: device)
        case .lg: LGDriver(device: device)
        }
    }

    // MARK: Connection

    func reconnect() {
        guard let driver else { return }
        switch state {
        case .connected, .connecting, .pairing: return
        default:
            relocationAttempted = false
            driver.connect()
        }
    }

    /// iOS kills sockets in the background without telling us, so the first press after
    /// returning would go into a dead connection. Drop it ourselves and reconnect on return.
    func sceneDidEnterBackground() {
        if case .pairing = state { return }
        driver?.disconnect()
    }

    func sceneDidBecomeActive() { reconnect() }

    /// Routers hand out new addresses. If a saved TV stops answering, look for one with the same
    /// brand and name elsewhere on the network and move it there. Pairing survives the move.
    private func relocate(_ device: TVDevice) {
        guard relocateTask == nil, !relocationAttempted else { return }
        relocationAttempted = true
        isRelocating = true
        relocateTask = Task {
            defer {
                isRelocating = false
                relocateTask = nil
            }
            if !discovery.isScanning { discovery.start() }
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, currentID == device.id else { return }
                if let match = discovery.found.first(where: {
                    $0.brand == device.brand && $0.name == device.name && $0.host != device.host
                }) {
                    move(device, to: match.host)
                    return
                }
                if !discovery.isScanning { return }
            }
        }
    }

    private func move(_ device: TVDevice, to host: String) {
        var moved = device
        moved.host = host
        devices.removeAll { $0.id == moved.id }
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            devices[i] = moved
        } else {
            devices.append(moved)
        }
        DeviceStore.save(devices)
        remoteModes.move(from: device.id, to: moved.id)
        activate(moved)
    }

    /// Explicit user action — this is the only path that puts something on the TV screen.
    func startPairing() { driver?.pair() }

    func submitPairingCode(_ code: String) { driver?.submitPairingCode(code) }

    func cancelPairing() {
        driver?.disconnect()
        driver?.connect()
    }

    // MARK: Commands

    #if DEBUG
    private(set) var demoInputCount = 0
    private(set) var demoLastInput = "None"
    #endif

    func press(_ key: RemoteKey) { driver?.send(key) }

    func pressInteractively(_ key: RemoteKey, request: RemoteInputRequest) async {
        guard state == .connected, !request.isCancelled, !Task.isCancelled else { return }
        #if DEBUG
        if DemoMode.isEnabled {
            demoInputCount += 1
            demoLastInput = key.accessibilityName
        }
        #endif
        await driver?.sendInteractive(key, request: request)
    }

    func supports(_ key: RemoteKey) -> Bool { driver?.supports(key) ?? true }

    func sendText(_ text: String) { driver?.sendText(text) }
    
    var supportsVoice: Bool { driver?.supportsVoice ?? false }
    
    func startVoice() async throws {
        try await driver?.startVoice()
    }
    
    func stopVoice() {
        driver?.stopVoice()
    }

    // MARK: Keyboard pad

    /// What's been typed on the keyboard pad since the last Return, for clear and for TVs that don't type live.
    var typed = ""

    var typesLive: Bool { driver?.typesLive ?? true }

    /// Each character goes to the TV as it's typed, where the TV appends what it's sent.
    func type(_ text: String) {
        typed += text
        if typesLive { sendText(text) }
    }

    func typeDelete() {
        if !typed.isEmpty { typed.removeLast() }
        if typesLive { press(.backspace) }
    }

    /// Deletes what's been typed since the last Return.
    func typeClear() {
        if typesLive {
            for _ in typed { press(.backspace) }
        }
        typed = ""
    }

    func typeReturn() {
        if typesLive {
            press(.enter)
        } else if !typed.isEmpty {
            sendText(typed)
        }
        typed = ""
    }

    /// Returns false when there's no paired TV to send it to.
    @discardableResult
    func launch(_ app: TVApp) -> Bool {
        guard let driver, current?.hasCredentials == true else { return false }
        driver.launch(app)
        return true
    }

    var allApps: [(app: TVApp, style: CatalogApp?)] {
        guard let brand = current?.brand else { return [] }
        if let installedApps, !installedApps.isEmpty {
            return installedApps.map { ($0, CatalogApp.match(name: $0.name)) }
        }
        return CatalogApp.all.compactMap { c in c.tvApp(for: brand).map { ($0, Optional(c)) } }
    }

    // MARK: Watch page apps

    private static let defaultAppIDs: Set<String> = ["youtube", "netflix", "prime", "disney", "appletv", "jellyfin"]

    /// Explicit choices only; missing entries follow the defaults without writing them to storage.
    private var appChoices: [String: Bool] = loadAppChoices() {
        didSet { CloudSettings.set(appChoices, forKey: CloudSettings.appChoices) }
    }

    private static func loadAppChoices() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: CloudSettings.appChoices) as? [String: Bool] ?? [:]
    }

    func isShown(_ app: TVApp) -> Bool {
        if let choice = appChoices[app.name.lowercased()] { return choice }
        guard let brand = current?.brand else { return false }
        return CatalogApp.all.contains { catalog in
            Self.defaultAppIDs.contains(catalog.id)
                && (catalog.launchID(for: brand) == app.launchID
                    || app.name.caseInsensitiveCompare(catalog.name) == .orderedSame)
        }
    }

    func setShown(_ app: TVApp, _ shown: Bool) {
        appChoices[app.name.lowercased()] = shown
    }

    var watchApps: [(app: TVApp, style: CatalogApp?)] {
        allApps.filter { isShown($0.app) }
    }

    func refreshApps() async {
        guard let driver else { return }
        if let apps = await driver.installedApps() {
            installedApps = apps
        }
    }

    // MARK: TVDriverDelegate

    func driver(_ driver: TVDriver, didChangeState state: ConnectionState) {
        guard driver === self.driver else { return }
        self.state = state
        if case .failed = state, let current {
            relocate(current)
        }
        if state == .connected, installedApps == nil {
            Task { await refreshApps() }
        }
    }

    func driver(_ driver: TVDriver, didUpdateDevice device: TVDevice) {
        guard let i = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[i] = device
        DeviceStore.save(devices)
    }
}
