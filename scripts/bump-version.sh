#!/bin/bash
set -euo pipefail

NEW_VERSION="${1:?Usage: bump-version.sh <version>}"

if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: version must be MAJOR.MINOR.PATCH" >&2
    exit 1
fi

echo "$NEW_VERSION" > VERSION

cat > Sources/LarimarShared/Version.swift << EOF
public enum LarimarVersion {
    public static let current = "$NEW_VERSION"
}
EOF

/usr/bin/plutil -replace CFBundleShortVersionString -string "$NEW_VERSION" Resources/Info.plist

echo "Bumped version to $NEW_VERSION"
echo "Files updated: VERSION, Version.swift, Info.plist"
echo "Run: make check-version && git add -A && git commit -m 'Bump version to $NEW_VERSION' && git tag v$NEW_VERSION"
