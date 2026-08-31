#!/usr/bin/env bash
#
# Runs the test suite on an iOS simulator.
#
# `swift test` builds for the macOS destination, where `canImport(UIKit)` is
# false. Two suites are fenced on it -- `ScreenPresentationTests` and
# `ScreenWebViewIntegrationTests` -- so a plain `swift test` silently skips
# them: they are the only coverage for `presentScreen`'s glue (document
# lookup, the offline path, package-resolution failures) and for the one thing
# that cannot be checked without a running WebKit, which is whether the runtime
# boots at all under the shell's CSP. Without this lane a CSP or shell
# regression from `sync_screen_runtime.sh` ships green.
#
# Usage:
#   scripts/test_ios.sh                 # first available iPhone simulator
#   scripts/test_ios.sh 'iPhone 17 Pro' # a named one
#   scripts/test_ios.sh '' ScreenWebViewIntegrationTests   # one suite
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICE="${1:-}"
FILTER="${2:-}"

if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun simctl list devices available \
    | sed -n 's/^ *\(iPhone[^(]*\) (.*/\1/p' \
    | sed 's/ *$//' \
    | head -1)
fi

if [ -z "$DEVICE" ]; then
  echo "error: no iPhone simulator is available. Install one from Xcode > Settings > Components." >&2
  exit 1
fi

echo "Running tests on: $DEVICE"

# `AppActor-Package`, not `AppActor`: SwiftPM's per-target scheme has no test
# action, and xcodebuild refuses it with "not currently configured for the test
# action". The package-wide scheme is the one that carries the test targets.
ARGS=(
  -scheme AppActor-Package
  -destination "platform=iOS Simulator,name=$DEVICE"
  -skipPackagePluginValidation
)

if [ -n "$FILTER" ]; then
  ARGS+=(-only-testing:"AppActorTests/$FILTER")
fi

# `xcodebuild test` rather than `swift test --destination`: SwiftPM can compile
# for the simulator triple from the command line but cannot link an XCTest
# bundle for it, so the run fails at the link step with nothing useful to say.
set -o pipefail
xcodebuild test "${ARGS[@]}" 2>&1 | tail -60
