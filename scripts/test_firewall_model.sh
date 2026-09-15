#!/usr/bin/env bash
# Executes Foundation-only animation/haptic tests on Linux, not the SwiftUI view.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
swiftc="${SWIFTC:-swiftc}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
cp "$root/App/Views/SignalWaveform.swift" .
sources=(SignalWaveform.swift)
if [[ -f "$root/App/Views/FirewallArmorGeometry.swift" ]]; then
    cp "$root/App/Views/FirewallArmorGeometry.swift" .
    sources+=(FirewallArmorGeometry.swift)
fi
"$swiftc" -emit-library -emit-module -enable-testing -module-name olcrtc_ios \
    "${sources[@]}" -o libolcrtc_ios.so
cp "$root/Tests/FirewallBeamTests.swift" "$root/Tests/SignalInteractionPolicyTests.swift" .
for test in "$root"/Tests/FirewallArmor*Tests.swift; do
    [[ ! -f "$test" ]] || cp "$test" .
done
# All included methods are synchronous, parameterless XCTest cases.
awk '
    BEGIN { print "import XCTest\n@testable import olcrtc_ios\nXCTMain([" }
    /^final class/ {
        if (seen++) print "]),"
        cls=$3; sub(/:.*/, "", cls); print "testCase(["
    }
    /^    func test/ {
        name=$2; sub(/\(.*/, "", name)
        print "(\"" name "\", " cls "." name "),"
    }
    END { print "])\n])" }
' *Tests.swift > main.swift
"$swiftc" -I . -L . -lolcrtc_ios *Tests.swift main.swift -o armor-tests
LD_LIBRARY_PATH="$work:${LD_LIBRARY_PATH:-}" ./armor-tests
