import SwiftUI

@main
struct OpenRemoteApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        #if os(macOS)
        MenuBarExtra("Open Remote", systemImage: "av.remote") {
            MenuBarRemoteView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        #endif
    }
}

#if os(macOS)
struct MenuBarRemoteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .frame(idealWidth: 420, idealHeight: 900)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gear")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .contentShape(Capsule())
                .keyboardShortcut(",", modifiers: .command)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.power)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .contentShape(Capsule())
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.background.opacity(0.95))
        }
    }
}
#endif

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Pager()
                .toolbar(.hidden)
                .jellyfinDestinations()
        }
            .safeAreaInset(edge: .bottom) { JellyfinStatusBar() }
            #if os(iOS)
            .background {
                VolumeButtons(isEnabled: scenePhase == .active && model.current != nil) { model.press($0) }
                    .frame(width: 1, height: 1)
            }
            #endif
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 760)
            #endif
            .sheet(isPresented: $model.showingDevices) { DevicesSheet() }
            .sheet(isPresented: $model.showingKeyboard) { KeyboardSheet() }
            .sheet(isPresented: $model.showingApps) { AppsSheet() }
            #if os(iOS)
            .sheet(isPresented: $model.showingSettings) { SettingsView() }
            #endif
            .sheet(isPresented: pairingPresented) { PairingSheet() }
            .animation(.snappy, value: model.state)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: model.sceneDidBecomeActive()
                case .background: model.sceneDidEnterBackground()
                default: break
                }
            }
            .task {
                if model.devices.isEmpty { model.showingDevices = true }
            }
    }

    private var pairingPresented: Binding<Bool> {
        Binding {
            if case .pairing = model.state { return true }
            return false
        } set: { presented in
            if !presented, case .pairing = model.state { model.cancelPairing() }
        }
    }
}

/// The remote and the Watch page side by side; swipe (or use the switcher) to move between them.
private struct Pager: View {
    @Environment(AppModel.self) private var model
    @AppStorage("page") private var stored = 0
    @State private var page: Int? = 0

    var body: some View {
        Group {
            if model.remoteControlMode.isGestureMode && (page ?? 0) == 0 {
                RemoteScreen()
            } else {
                pages
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.remoteControlMode.isGestureMode || (page ?? 0) != 0 {
                PageSwitcher(page: Binding { page ?? 0 } set: { new in withAnimation(.snappy) { page = new } })
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { page = stored }
        .onChange(of: page) { _, new in if let new { stored = new } }
        .onChange(of: stored) { _, new in if page != new { page = new } }
    }

    private var pages: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                RemoteScreen()
                    .containerRelativeFrame(.horizontal)
                    .id(0)
                WatchScreen()
                    .containerRelativeFrame(.horizontal)
                    .id(1)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)

    }
}

struct PageSwitcher: View {
    static let height: CGFloat = 44
    @Binding var page: Int

    var body: some View {
        HStack(spacing: 4) {
            tab("Remote", systemImage: "av.remote", index: 0, key: "1")
            tab("Watch", systemImage: "play.rectangle.on.rectangle", index: 1, key: "2")
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private func tab(_ title: String, systemImage: String, index: Int, key: KeyEquivalent) -> some View {
        Button {
            Haptics.tick()
            page = index
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(page == index ? Color.black : Theme.secondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(page == index ? Theme.accent : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityAddTraits(page == index ? .isSelected : [])
    }
}
