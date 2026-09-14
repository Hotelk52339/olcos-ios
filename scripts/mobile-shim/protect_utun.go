// zz_olcrtcios_utun.go — olcrtc-ios BUILD SHIM, not upstream code.
//
// Upstream's ICE interface filter (internal/protect/pionnet.go)
// excludes tunnel-style interfaces by name prefix — {"tun", "ppp", "pptp"} —
// but iOS names its tunnel interfaces utunN (and IPsec tunnels ipsecN).
// Without this fix, pion gathers host candidates on the packet-tunnel
// provider's OWN utun (198.18.0.1): ICE noise at best, a routing loop hazard
// at worst. tunInterfacePrefixes is a package var read at call time by
// isTunInterface, so appending in init() needs no patching of upstream files.
//
// scripts/build-framework.sh copies this file into
// olcrtc-upstream/internal/protect/ right before `gomobile bind` and
// trap-deletes it after, so the submodule stays clean and nothing here is
// ever committed into upstream. (A matching one-line upstream PR retires it.)
package protect

//nolint:gochecknoinits // build shim: must run before any interface enumeration
func init() {
	tunInterfacePrefixes = append(tunInterfacePrefixes, "utun", "ipsec")
}
