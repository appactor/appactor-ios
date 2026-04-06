#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/Sources/AppActor/Internal/SDKVersion.swift"

usage() {
  echo "Usage: $0 [version]"
  echo
  echo "If no version is provided, the latest git tag is used."
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

if [[ $# -eq 1 ]]; then
  VERSION="$1"
else
  VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
fi

if [[ -z "$VERSION" ]]; then
  echo "Could not resolve a version. Pass one explicitly or create a git tag first." >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
  echo "Version must look like semver, got: $VERSION" >&2
  exit 1
fi

CURRENT_VERSION="$(awk -F '\"' '/static let version = / { print $2 }' "$VERSION_FILE")"
if [[ "$CURRENT_VERSION" == "$VERSION" ]]; then
  echo "AppActor SDK version already $VERSION"
  exit 0
fi

perl -0pi -e "s/static let version = \".*?\"/static let version = \"$VERSION\"/" "$VERSION_FILE"

echo "Synced AppActor SDK version to $VERSION"
echo "Updated: $VERSION_FILE"
