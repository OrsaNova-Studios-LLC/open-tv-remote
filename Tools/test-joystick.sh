#!/bin/sh
# Host-only tests: no simulator, device, network, TV discovery, or signing.
set -eu
cd "$(dirname "$0")/.."
package="$PWD/build/joystick-tests"
mkdir -p "$package/Sources/JoystickCore" "$package/Tests/JoystickCoreTests"
cp Sources/Core/RemoteControlMode.swift Sources/Core/TVDeviceSync.swift Sources/Core/RemoteInputAvailability.swift Sources/Core/RemoteKey.swift Sources/Core/JoystickInput.swift Sources/Core/TVDriver.swift Sources/Core/TVDevice.swift \
  Sources/Drivers/RokuDriver.swift Sources/Drivers/LGDriver.swift Tests/Support/RemoteTransportStubs.swift "$package/Sources/JoystickCore/"
cp Tests/RemoteModeTests.swift Tests/TVDeviceSyncTests.swift Tests/RemoteInputAvailabilityTests.swift Tests/JoystickInputTests.swift Tests/RemoteDriverTests.swift "$package/Tests/JoystickCoreTests/"
cat > "$package/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "JoystickCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "JoystickCore"),
    .testTarget(name: "JoystickCoreTests", dependencies: ["JoystickCore"])
], swiftLanguageModes: [.v5])
PACKAGE
swift test --package-path "$package" --jobs 2
