#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc Sources/Usage.swift Tests/main.swift -o "$TEST_DIR/UsageTests"
"$TEST_DIR/UsageTests" "$PWD/Resources/prices.json"
