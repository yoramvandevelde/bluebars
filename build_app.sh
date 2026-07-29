#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="BlueBards Local Signing"

swift build -c debug
cp .build/arm64-apple-macosx/debug/BlueBars BlueBars.app/Contents/MacOS/BlueBars
codesign --force --deep --sign "$SIGN_IDENTITY" BlueBars.app

echo "Built BlueBars.app. Launch with: open BlueBars.app"
