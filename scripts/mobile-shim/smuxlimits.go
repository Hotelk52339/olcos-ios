// zz_olcrtcios_smuxlimits.go — olcrtc-ios BUILD SHIM, not upstream code.
//
// Upstream declares smuxMaxReceiveBuffer (32 MiB) and smuxMaxStreamBuffer
// (4 MiB) as CONSTS inside internal/runtime/runtime.go's const block, consumed
// by SmuxConfig. 32 MiB of perfectly legal buffering during a bulk download
// jetsams the ~50 MB iOS Network Extension, and a copied-in file can neither
// redeclare a const nor override SmuxConfig — so this is the one shim that
// needs a build-time patch:
//
// scripts/build-framework.sh DELETES exactly those two const lines from
// olcrtc-upstream/internal/runtime/runtime.go (grep-anchored so upstream
// drift fails loudly), copies this file in as
// internal/runtime/zz_olcrtcios_smuxlimits.go re-declaring them as package
// vars with the identical default values, and trap-restores the submodule
// (git checkout of runtime.go + rm of the shim copy) on any exit — nothing
// here is ever committed into upstream. (An upstream const→var+setter PR
// retires both the patch and this file.)
//
// The extension calls the setter (via mobile.SetMuxBuffers in
// zz_olcrtcios_memory.go) BEFORE Runtime.Start; SmuxConfig reads the vars
// when a smux session is created, so there is no concurrent mutation.
package runtime

// Upstream default values, re-declared as vars so the mobile shim can lower
// them for the memory-capped iOS Network Extension.
//
//nolint:gochecknoglobals // replaces upstream consts; see file header
var (
	smuxMaxReceiveBuffer = 32 * 1024 * 1024
	smuxMaxStreamBuffer  = 4 * 1024 * 1024
)

// SetSmuxBufferLimits caps the smux session (maxReceive) and per-stream
// (maxStream) receive buffers used by future SmuxConfig calls. Values <= 0
// leave the corresponding limit unchanged. Call before any session exists;
// live sessions keep the config they were created with.
func SetSmuxBufferLimits(maxReceive, maxStream int) {
	if maxReceive > 0 {
		smuxMaxReceiveBuffer = maxReceive
	}
	if maxStream > 0 {
		smuxMaxStreamBuffer = maxStream
	}
}
