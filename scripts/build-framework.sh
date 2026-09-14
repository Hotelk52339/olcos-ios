#!/usr/bin/env bash
# #253: Build App/Mobile.xcframework with gomobile — upstream's mobile package
# plus the local tun2socks glue (gomobile/tunstack, #vpn), bound TOGETHER from
# the gomobile/ wrapper module into ONE xcframework (two separately built
# gomobile frameworks cannot be linked into one binary: duplicate Go runtimes).
#
# Single source of truth for the framework build — humans, CI (ci.yml) and the
# release workflow (release.yml) all call this. Prefer the prebuilt download
# (./scripts/fetch-framework.sh) unless you are building against a moved submodule
# pin or changing olcrtc-upstream/mobile/*.go, scripts/mobile-shim/*, or
# gomobile/tunstack/*.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/olcrtc-upstream"
OUT="$ROOT/App/Mobile.xcframework"
RUNTIME_GO="$UPSTREAM/internal/runtime/runtime.go"

# #442: upstream master split mobile.go into runtime.go/config.go/probe.go/… —
# guard on runtime.go, the entry point of the new instance API.
if [ ! -f "$UPSTREAM/mobile/runtime.go" ]; then
  echo "error: $UPSTREAM/mobile/runtime.go missing — run: git submodule update --init --recursive" >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "error: Go toolchain not found. Install Go (the version pinned in olcrtc-upstream/go.mod), e.g. 'brew install go'." >&2
  exit 1
fi

# gomobile installs into $(go env GOPATH)/bin, which isn't on PATH by default.
export PATH="$PATH:$(go env GOPATH)/bin"

# #vpn: resolve the wrapper module's deps and (re)generate gomobile/go.sum —
# it is not committed, and both `go list -m` and the bind below need it.
(cd "$ROOT/gomobile" && go mod tidy)

# #442: pin the gomobile CLI to the x/mobile version the wrapper module requires
# (gomobile/go.mod keeps it in lockstep with olcrtc-upstream/go.mod), so the
# code generator and the bound runtime (golang.org/x/mobile/bind) cannot drift
# (installing @latest risks a generator/runtime mismatch).
GOMOBILE_VER="$(cd "$ROOT/gomobile" && go list -m -f '{{.Version}}' golang.org/x/mobile)"
echo "note: installing golang.org/x/mobile/cmd/gomobile@${GOMOBILE_VER} ..."
go install "golang.org/x/mobile/cmd/gomobile@${GOMOBILE_VER}"
gomobile init

# Build-time shims copied into the submodule for the duration of the bind and
# trap-removed afterwards, so the submodule stays clean even if the bind fails:
#   logbridge    (#442) re-adds mobile.SetLogWriter for LogStore/WedgeDetector.
#   memory       (#vpn) MobileTuneForNetworkExtension / MobileFreeOSMemory /
#                MobileSetMuxBuffers — Go memory knobs for the ~50 MB NE cap.
#   protect_utun (#vpn) appends "utun"/"ipsec" to pion's tun-interface filter.
#   smuxlimits   (#vpn) re-declares the smux buffer consts as vars + setter;
#                needs the two upstream const lines deleted (patch below).
SHIM_DSTS=(
  "$UPSTREAM/mobile/zz_olcrtcios_logbridge.go"
  "$UPSTREAM/mobile/zz_olcrtcios_memory.go"
  "$UPSTREAM/internal/protect/zz_olcrtcios_utun.go"
  "$UPSTREAM/internal/runtime/zz_olcrtcios_smuxlimits.go"
)
trap 'rm -f "${SHIM_DSTS[@]}"; git -C "$UPSTREAM" checkout -- internal/runtime/runtime.go' EXIT

# Self-heal: if a previous run died before its trap could fire (e.g. SIGKILL),
# runtime.go may still carry the smux patch — restore it first so the anchors
# below match again and reruns stay idempotent.
git -C "$UPSTREAM" checkout -- internal/runtime/runtime.go

cp "$ROOT/scripts/mobile-shim/logbridge.go"    "${SHIM_DSTS[0]}"
cp "$ROOT/scripts/mobile-shim/memory.go"       "${SHIM_DSTS[1]}"
cp "$ROOT/scripts/mobile-shim/protect_utun.go" "${SHIM_DSTS[2]}"
cp "$ROOT/scripts/mobile-shim/smuxlimits.go"   "${SHIM_DSTS[3]}"

# #vpn: smuxMaxReceiveBuffer (32 MiB) / smuxMaxStreamBuffer (4 MiB) are CONSTS
# upstream — a copied-in shim cannot redeclare them, so delete exactly those two
# lines; the smuxlimits shim re-declares them as vars with identical defaults
# plus SetSmuxBufferLimits. grep-anchored so upstream drift fails loudly instead
# of silently binding the 32 MiB default; the trap's git checkout restores the
# file on any exit. (Retire this once upstream lands the const→var+setter PR.)
grep -qF 'smuxMaxReceiveBuffer = 32 * 1024 * 1024' "$RUNTIME_GO" || {
  echo "error: smux anchor 'smuxMaxReceiveBuffer = 32 * 1024 * 1024' not found in $RUNTIME_GO — upstream drifted; update the patch here and scripts/mobile-shim/smuxlimits.go" >&2
  exit 1
}
grep -qF 'smuxMaxStreamBuffer  = 4 * 1024 * 1024' "$RUNTIME_GO" || {
  echo "error: smux anchor 'smuxMaxStreamBuffer  = 4 * 1024 * 1024' (two spaces before =, gofmt alignment) not found in $RUNTIME_GO — upstream drifted; update the patch here and scripts/mobile-shim/smuxlimits.go" >&2
  exit 1
}
perl -ni -e 'print unless /^\tsmuxMaxReceiveBuffer = 32 \* 1024 \* 1024$/ || /^\tsmuxMaxStreamBuffer  = 4 \* 1024 \* 1024$/' "$RUNTIME_GO"

echo "note: gomobile bind -target=ios -> $OUT (~5 min on first run) ..."
cd "$ROOT/gomobile"
gomobile bind -target=ios -o "$OUT" github.com/openlibrecommunity/olcrtc/mobile ./tunstack

echo "done:  $OUT"
echo "next:  xcodegen generate --spec project.yml   # so Xcode picks up the framework"
