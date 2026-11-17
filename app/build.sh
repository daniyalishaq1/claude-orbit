#!/bin/zsh
# Builds build/Claude Orbit.app with the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "${0:A:h}"
APP="build/Claude Orbit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14" \
  -framework SwiftUI -framework AppKit \
  Sources/*.swift -o "$APP/Contents/MacOS/ClaudeOrbit"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns Resources/MenuBarIcon.svg "$APP/Contents/Resources/"   # AppIcon.icns comes from make-icon.swift
codesign -s - --force "$APP" >/dev/null 2>&1
echo "BUILD OK: $PWD/$APP"
