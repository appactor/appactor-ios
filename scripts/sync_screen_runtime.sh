#!/usr/bin/env bash
#
# Regenerates Sources/AppActor/Internal/Screens/ScreenRuntimeAsset.swift from a
# built appactor-screens runtime.
#
#   ./scripts/sync_screen_runtime.sh [path-to-appactor-screens]
#
# Defaults to ../../appactor-screens, which is where it sits in the usual
# checkout layout. Run `pnpm run build` over there first -- this script reads
# packages/runtime/dist and does not build anything itself.
#
# ## Why the runtime is a Swift string and not a bundled resource
#
# `.copy("Resources/runtime.js")` in Package.swift would give SwiftPM consumers
# a `Bundle.module`, and CocoaPods consumers nothing: the podspec ships
# `Sources/AppActor/**/*.swift` and `Bundle.module` does not exist in a Pod
# build at all. Every workaround (a second resource_bundles entry plus a
# `#if SWIFT_PACKAGE` resolver) is more moving parts than a generated Swift
# file, which both build systems already know how to compile.
#
# Fetching it from a CDN instead is the eventual answer -- versioned immutable
# paths, a canary channel and a rollback runbook are their own piece of work,
# and until that exists an embedded runtime is also what makes the screen open
# in airplane mode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENS_REPO="${1:-$REPO_ROOT/../../appactor-screens}"

DIST="$SCREENS_REPO/packages/runtime/dist"
RUNTIME_JS="$DIST/runtime.js"
SHELL_HTML="$DIST/index.html"
OUT="$REPO_ROOT/Sources/AppActor/Internal/Screens/ScreenRuntimeAsset.swift"

for f in "$RUNTIME_JS" "$SHELL_HTML"; do
  if [[ ! -f "$f" ]]; then
    echo "error: $f not found. Run 'pnpm run build' in $SCREENS_REPO first." >&2
    exit 1
  fi
done

# The Swift literals are raw (#"""..."""#). Two things can break out of one:
# the closing delimiter, and the escape introducer -- which in a single-pound
# raw string is `\#`, not `\`. That second one is silent where it matters:
# `\#u{41}` in the input becomes a literal `A` in the generated file, and
# `\#n` becomes a newline, so the SDK would ship a runtime that differs from
# the one that was built and tested. Both are checked before anything is
# escaped, so the `\#u{..}` sequences this script inserts below are not
# mistaken for input.
for f in "$RUNTIME_JS" "$SHELL_HTML"; do
  if grep -q '"""#' "$f"; then
    echo "error: $f contains the raw-string terminator; the generator cannot embed it." >&2
    exit 1
  fi
  if grep -q '\\#' "$f"; then
    echo "error: $f contains \\# , the raw-string escape introducer; embedding it would silently rewrite the runtime." >&2
    exit 1
  fi
done

# Swift rejects unprintable ASCII in source, and the minified runtime carries a
# literal U+0001 as an array join separator. Inside a `#"""` literal the escape
# hatch is `\#u{..}`, which produces the same byte without the compiler ever
# seeing it. Newline and tab are left alone -- both are legal in a multiline
# literal and rewriting them would only make the file unreadable.
escape_control() {
  perl -0pe 's/([\x00-\x08\x0B\x0C\x0E-\x1F\x7F])/sprintf("\\#u{%02X}", ord($1))/ge'
}

# Read from the spec rather than the minified bundle: the constant survives
# there under a name, and in dist/runtime.js it is an inlined string literal
# indistinguishable from any other.
CONSTANTS="$SCREENS_REPO/packages/schema/src/spec/constants.ts"
VERSION="$(sed -n "s/.*RUNTIME_VERSION = '\([0-9][0-9.]*\)'.*/\1/p" "$CONSTANTS" | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "error: could not read RUNTIME_VERSION from $CONSTANTS" >&2
  exit 1
fi

GZIP_BYTES="$(gzip -9 -c "$RUNTIME_JS" | wc -c | tr -d ' ')"

# The shell ships with <script src="runtime.js">, which only resolves for a page
# served off a real origin. Here the runtime is injected as a WKUserScript
# instead, so the tag is dropped -- see the header comment in the generated file.
STRIPPED_HTML="$(perl -0pe 's{<script src="runtime\.js"></script>\s*}{}g' "$SHELL_HTML" | escape_control)"

{
  cat <<SWIFT
// GENERATED FILE -- DO NOT EDIT.
//
// Produced by scripts/sync_screen_runtime.sh from appactor-screens
// packages/runtime/dist (runtime $VERSION, ${GZIP_BYTES} bytes gzipped).
// Re-run that script to update; hand edits are lost on the next sync.

import Foundation

enum AppActorScreenRuntimeAsset {

    /// Runtime version this SDK build carries. Reported alongside the version
    /// the runtime announces in \`ready\`, so a mismatch is visible in a log
    /// rather than only in behaviour.
    static let version = "$VERSION"

    /// The page shell: CSP, viewport, safe-area variables and the base CSS that
    /// has to paint before any JavaScript runs.
    ///
    /// The upstream shell ends with \`<script src="runtime.js">\`. That tag is
    /// stripped here and the runtime is injected as a \`WKUserScript\` instead,
    /// for two reasons. A relative subresource would be fetched over the
    /// network from the simulated origin, which loses the airplane-mode case
    /// the disk cache exists to serve. And inlining the script into the HTML
    /// would need the shell's \`script-src 'self'\` relaxed to a hash or to
    /// \`unsafe-inline\` -- weakening the one policy that keeps a hole in the
    /// runtime from becoming code execution. User scripts run before the page's
    /// own policy applies, so the CSP below stays exactly as the screens repo
    /// wrote it.
    static let shellHTML = #"""
SWIFT
  printf '%s\n' "$STRIPPED_HTML"
  cat <<'SWIFT'
"""#

    /// The runtime bundle, injected at document end.
    static let runtimeJS = #"""
SWIFT
  escape_control < "$RUNTIME_JS"
  cat <<'SWIFT'
"""#
}
SWIFT
} > "$OUT"

echo "wrote $OUT (runtime $VERSION, ${GZIP_BYTES} B gzip)"
