// Wrapper module for the iOS gomobile bind (#vpn). It exists so the repo can
// bind upstream's mobile package TOGETHER WITH the local tunstack tun2socks
// glue into the single App/Mobile.xcframework without forking upstream:
//
//   cd gomobile && gomobile bind -target=ios -o ../App/Mobile.xcframework \
//     github.com/openlibrecommunity/olcrtc/mobile ./tunstack
//
// Two separately built gomobile frameworks cannot be linked into one binary
// (duplicate Go runtime symbols), so both packages must come out of ONE bind.
//
// go.sum is generated in CI: run `go mod tidy` here before the first bind.
// golang.org/x/mobile is pinned to the exact version olcrtc-upstream/go.mod
// requires, so the gomobile CLI (installed at this version by
// scripts/build-framework.sh) and the bound bind runtime cannot drift.
module github.com/openlibrecommunity/olcrtc-ios/gomobile

go 1.26.3

require (
	github.com/Jigsaw-Code/outline-sdk v0.0.20
	github.com/openlibrecommunity/olcrtc v0.0.0-00010101000000-000000000000
	golang.org/x/mobile v0.0.0-20260520154334-0e4426e1883d
)

replace github.com/openlibrecommunity/olcrtc => ../olcrtc-upstream
