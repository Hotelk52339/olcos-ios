// zz_olcrtcios_memory.go — olcrtc-ios BUILD SHIM, not upstream code.
//
// The iOS packet-tunnel extension runs the whole Go core under a ~50 MB
// jetsam cap. This shim exports the memory knobs the extension needs:
// a Go-heap soft limit + aggressive GC (TuneForNetworkExtension), an
// on-memory-pressure release valve (FreeOSMemory), and a forwarder to the
// smux buffer limiter that lives in internal/runtime (SetMuxBuffers).
//
// Living inside package `mobile` gives gomobile the Swift names
// MobileTuneForNetworkExtension / MobileFreeOSMemory / MobileSetMuxBuffers,
// and — because Go's internal-package rule gates the importer's package path,
// not file provenance — legally lets this file import
// github.com/openlibrecommunity/olcrtc/internal/runtime.
//
// scripts/build-framework.sh copies this file into olcrtc-upstream/mobile/
// right before `gomobile bind` and trap-deletes it after, so the submodule
// stays clean and nothing here is ever committed into upstream.
package mobile

import (
	"runtime/debug"

	olcruntime "github.com/openlibrecommunity/olcrtc/internal/runtime"
)

// defaultNEMemoryLimitBytes is the Go soft memory limit used when the caller
// passes no explicit value: 30 MiB, leaving headroom under the ~50 MB
// Network Extension cap for cgo/lwIP, pion buffers, and the ObjC side.
const defaultNEMemoryLimitBytes = 30 << 20

// TuneForNetworkExtension tightens the Go runtime for life inside an iOS
// Network Extension: GC at 20% heap growth plus a soft memory limit of
// memoryLimitBytes (values <= 0 select the 30 MiB default). Call it once,
// before the runtime starts. The same knobs sing-box/libbox ships for its
// provider process.
func TuneForNetworkExtension(memoryLimitBytes int64) {
	if memoryLimitBytes <= 0 {
		memoryLimitBytes = defaultNEMemoryLimitBytes
	}
	debug.SetGCPercent(20)
	debug.SetMemoryLimit(memoryLimitBytes)
}

// FreeOSMemory forces a GC and returns as much memory to the OS as possible.
// The provider calls it from its DispatchSource memory-pressure handler.
func FreeOSMemory() {
	debug.FreeOSMemory()
}

// SetMuxBuffers caps the smux session (maxReceive) and per-stream (maxStream)
// receive buffers for sessions created after the call — upstream's 32 MiB
// session default alone can jetsam the extension during a bulk download.
// Values <= 0 leave the corresponding limit unchanged. Call before Start.
func SetMuxBuffers(maxReceive, maxStream int) {
	olcruntime.SetSmuxBufferLimits(maxReceive, maxStream)
}
