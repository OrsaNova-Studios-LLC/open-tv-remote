import SwiftUI

struct RemoteNavigationRow: View {
    @Binding var selection: RemoteControlMode
    var modes: [RemoteControlMode]
    let enabled: Bool
    let back: () -> Void
    let home: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            navigationButton("Back", symbol: "arrow.uturn.backward", action: back)
            RemoteModePicker(selection: $selection, modes: modes)
            navigationButton("Home", symbol: "house.fill", action: home)
        }
        .frame(height: 54)
    }

    private func navigationButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.label)
                .frame(width: 48, height: 54)
                .background(KeySurface(shape: RoundedRectangle(cornerRadius: 18)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

private struct RemoteModePicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: RemoteControlMode
    let modes: [RemoteControlMode]

    var body: some View {
        GeometryReader { geo in
            if !dynamicTypeSize.isAccessibilitySize && geo.size.width >= CGFloat(modes.count) * 44 + 10 {
                HStack(spacing: 0) {
                    ForEach(modes) { mode in
                        Button { selection = mode } label: {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(selection == mode ? Color.black : Theme.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Capsule().fill(selection == mode ? Theme.accent : .clear))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(mode.title)
                        .accessibilityIdentifier("remoteMode-" + mode.rawValue)
                        .accessibilityAddTraits(selection == mode ? .isSelected : [])
                    }
                }
                .padding(5)
            } else {
                Menu {
                    Picker("Control mode", selection: $selection) {
                        ForEach(modes) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                    }
                } label: {
                    Label(selection.title, systemImage: selection.symbol)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Capsule())
                }
                .menuIndicator(.visible)
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .accessibilityLabel("Control mode, " + selection.title)
            }
        }
        .background(Capsule().fill(Theme.well))
        .overlay(Capsule().strokeBorder(.white.opacity(0.05), lineWidth: 1))
        .accessibilityIdentifier("remoteModePicker")
    }
}

/// The navigation row keeps one position while only the input area changes or scrolls.
struct RemoteModeLayout<Navigation: View, Controls: View>: View {
    private let navigation: Navigation
    private let controls: Controls

    init(@ViewBuilder navigation: () -> Navigation, @ViewBuilder controls: () -> Controls) {
        self.navigation = navigation()
        self.controls = controls()
    }

    var body: some View {
        VStack(spacing: 12) {
            navigation
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
