#!/bin/sh
# Builds the dev harness and signs it with a stable identity so the keychain's
# "Always Allow" survives rebuilds (unsigned builds look like a new app each time).
set -e
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -swift-version 5 -O -o build/harness Tools/harness/main.swift \
  Sources/Core/RemoteKey.swift Sources/Core/TVDevice.swift Sources/Core/TVDriver.swift Sources/Core/JoystickInput.swift \
  Sources/Net/*.swift Sources/Drivers/AndroidTVDriver.swift
codesign --force --sign "${CODESIGN_IDENTITY:-Apple Development}" --identifier com.natebutler.freeremote.harness build/harness
