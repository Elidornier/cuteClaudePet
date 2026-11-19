#!/bin/bash
# Rebuild 小 Claude (ApprovalPet.app) from src/main.swift.
set -euo pipefail
cd "$(dirname "$0")"
APP=ApprovalPet.app
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -framework AppKit src/main.swift -o "$APP/Contents/MacOS/ApprovalPet"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built $(pwd)/$APP"
