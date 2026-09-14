#!/bin/bash
# #452: multi-carrier VPS — attach an EXTRA carrier to an existing install.
#
# scripts/srv.sh installs the primary carrier: it builds ./olcrtc in
# /opt/olcrtc-deploy-<id>, writes server.yaml and runs the container
# olcrtc-server-<id>. This script adds one more carrier to that SAME install
# without rebuilding anything: it writes server-<carrier>.yaml next to
# server.yaml (same key, same binary) and runs a sibling container named
# "<base-container>-<carrier>" off the same deploy dir and image. Every
# carrier then sits in its own conference room 24/7 and the app picks which
# one to connect through. #481 was: re-adding replaced a same-named sibling.
# An occupied sibling slot is now rejected without changing it, and NEVER touches the
# base container. srv.sh's reinstall sweep and the app's uninstall
# prefix-sweep remove siblings together with the primary.
#
# It is uploaded over SSH the same way srv.sh is (base64-encoded printf, see
# SSHRunner.addCarrier) and driven by env vars:
#   OLCRTC_BASE_CONTAINER — required; the olcrtc-server-* container of the
#                           primary install (resolves deploy dir, binary, key)
#   OLCRTC_CARRIER        — required; telemost | wbstream | jitsi
#   OLCRTC_TRANSPORT      — required; datachannel | vp8channel | seichannel | videochannel
#   OLCRTC_ROOM_ID        — required for telemost/wbstream. jitsi: a full
#                           http(s) URL (verbatim), a short room name
#                           (prefixed with the base), or empty (auto-generated)
#   OLCRTC_JITSI_URL      — jitsi base URL (same default as srv.sh)
#   OLCRTC_WB_TOKEN       — optional wbstream account token (auth.token)
#   OLCRTC_DNS            — DNS resolver (same default as srv.sh)
#   OLCRTC_SOCKS_PROXY_ADDR / OLCRTC_SOCKS_PROXY_PORT — optional egress proxy
#   OLCRTC_VP8_FPS / OLCRTC_VP8_BATCH                 — vp8channel tuning
#   OLCRTC_SEI_FPS / OLCRTC_SEI_BATCH / OLCRTC_SEI_FRAG / OLCRTC_SEI_ACK — seichannel tuning
#   OLCRTC_VIDEO_W / OLCRTC_VIDEO_H / OLCRTC_VIDEO_FPS / OLCRTC_VIDEO_CODEC /
#   OLCRTC_VIDEO_QR_SIZE / OLCRTC_VIDEO_QR_RECOVERY /
#   OLCRTC_VIDEO_TILE_MODULE / OLCRTC_VIDEO_TILE_RS   — videochannel tuning
#   OLCRTC_CONFIG_NAME    — optional; URI $-tail marker (default auto-provisioned)
# No pin env var: nothing is cloned or built here — the existing binary is
# necessarily at the pinned commit the primary install fetched.
#
# The key is REUSED, never rotated: ~/.olcrtc_key first, the base
# server.yaml's crypto.key as fallback — every carrier on one host shares one
# key, which is what lets scripts/rotate-key.sh rotate them all in lockstep.
#
# Output contract (machine-read by SSHRunner.parseInstallResult, same as
# srv.sh): on success the last lines are
#   OLCRTC_URI=olcrtc://<carrier>?<transport>[<payload>]@<room>#<key>$<configname>
#   OLCRTC_CONTAINER=<base>-<carrier>
#   OLCRTC_CARRIER_ADDED=ok
# Any failure prints "ERROR: <reason>" to stderr and exits 1 (reaches the app
# through _execute's stderr merge as ProvisionError.sshCommand).
#
# srv.sh parity: blocks copied verbatim from scripts/srv.sh are wrapped in
# `# boc srv.sh` / `# eoc srv.sh` markers. Tests/AddCarrierScriptTests.swift
# verifies every non-comment line inside those markers still appears verbatim
# (whitespace-trimmed) in scripts/srv.sh, so the two cannot drift silently —
# same guarantee RotateKeyScriptTests gives rotate-key.sh.

set -e

BASE_CONTAINER="${OLCRTC_BASE_CONTAINER:?OLCRTC_BASE_CONTAINER is required}"

if ! podman ps -a --format '{{.Names}}' | grep -q "^${BASE_CONTAINER}$" 2>/dev/null; then
    echo "ERROR: container ${BASE_CONTAINER} not found" >&2
    exit 1
fi

PROVIDER="${OLCRTC_CARRIER:?OLCRTC_CARRIER is required}"
case "$PROVIDER" in
    telemost|wbstream|jitsi) : ;;
    *)
        echo "ERROR: unsupported carrier '${PROVIDER}' (expected telemost, wbstream or jitsi)" >&2
        exit 1
        ;;
esac

TRANSPORT="${OLCRTC_TRANSPORT:?OLCRTC_TRANSPORT is required}"

# Locate the deploy dir through the container's bind mount — same strategy as
# rotate-key.sh / SSHRunner.reconfigureScript. Named WORK_DIR so the verbatim
# srv.sh lines below apply unchanged.
WORK_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "${BASE_CONTAINER}")
if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
    echo "ERROR: deploy dir not found for ${BASE_CONTAINER}" >&2
    exit 1
fi
if [ ! -x "$WORK_DIR/olcrtc" ]; then
    echo "ERROR: olcrtc binary not built in ${WORK_DIR} — run the full install first" >&2
    exit 1
fi

# boc srv.sh: shared install constants and helpers (verbatim)
IMAGE_NAME="docker.io/library/golang:1.26-alpine3.22"
MODE="srv"
validate_key() {
    case "$1" in
        *[!0-9a-fA-F]*)
            return 1
            ;;
    esac
    [ "${#1}" -eq 64 ]
}
# eoc srv.sh

# --- Reuse the install's encryption key --------------------------------------
# boc srv.sh: load-existing-key branch — srv.sh's srv key handling. Reuse, not
# rotation: every carrier on the host must share the primary's key.
KEY_FILE="$HOME/.olcrtc_key"
if [ -f "$KEY_FILE" ]; then
    echo "[*] Loading existing encryption key..."
    KEY=$(tr -d '[:space:]' < "$KEY_FILE")
fi
# eoc srv.sh
if ! validate_key "${KEY:-}"; then
    # ~/.olcrtc_key missing or corrupt — fall back to the key the primary
    # server.yaml runs with (srv.sh writes both; reconfigure keeps them in sync).
    KEY=$(sed -n 's/^  key: "\(.*\)"$/\1/p' "$WORK_DIR/server.yaml" 2>/dev/null | head -1)
fi
if ! validate_key "${KEY:-}"; then
    echo "ERROR: no valid encryption key in ${KEY_FILE} or ${WORK_DIR}/server.yaml — repair the install first (rotate key)" >&2
    exit 1
fi

# --- Room selection (same semantics as srv.sh's env patch) -------------------
# boc srv.sh: room from env; jitsi base-URL normalisation
ROOM_ID="${OLCRTC_ROOM_ID:-}"
if [ "$PROVIDER" = "jitsi" ]; then
    JITSI_BASE="${OLCRTC_JITSI_URL:-https://meet1.arbitr.ru}"
    JITSI_BASE="${JITSI_BASE%/}"
# eoc srv.sh
    # Same room shapes as srv.sh: full URL verbatim, short name prefixed,
    # empty auto-generated — but with a fresh random suffix (there is no
    # RUN_ID here; the deploy id belongs to the primary install).
    case "$ROOM_ID" in
        http://*|https://*) : ;;
        "")  NEW_ID=$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)
             ROOM_ID="$JITSI_BASE/olcrtc-$NEW_ID"
             echo "[*] Generated Jitsi room URL: $ROOM_ID" ;;
        *)   ROOM_ID="$JITSI_BASE/$ROOM_ID" ;;
    esac
fi
# boc srv.sh: non-jitsi carriers need an explicit room id
[ -n "$ROOM_ID" ] || { echo "[X] OLCRTC_ROOM_ID is required"; exit 1; }
# eoc srv.sh

# --- Remaining knobs (same env contract and defaults as srv.sh) --------------
# boc srv.sh: DNS / egress-proxy / transport-tuning env patches (verbatim)
DNS="${OLCRTC_DNS:-77.88.8.8:53}"
SOCKS_PROXY_ADDR="${OLCRTC_SOCKS_PROXY_ADDR:-}"
SOCKS_PROXY_PORT="${OLCRTC_SOCKS_PROXY_PORT:-0}"
WB_TOKEN="${OLCRTC_WB_TOKEN:-}"
VIDEO_W="${OLCRTC_VIDEO_W:-1920}"; VIDEO_H="${OLCRTC_VIDEO_H:-1080}"
VIDEO_FPS="${OLCRTC_VIDEO_FPS:-30}"; VIDEO_CODEC="${OLCRTC_VIDEO_CODEC:-qrcode}"
VIDEO_QR_SIZE="${OLCRTC_VIDEO_QR_SIZE:-0}"; VIDEO_QR_RECOVERY="${OLCRTC_VIDEO_QR_RECOVERY:-low}"
VIDEO_TILE_MODULE="${OLCRTC_VIDEO_TILE_MODULE:-4}"; VIDEO_TILE_RS="${OLCRTC_VIDEO_TILE_RS:-20}"
VP8_FPS="${OLCRTC_VP8_FPS:-25}"; VP8_BATCH="${OLCRTC_VP8_BATCH:-1}"
SEI_FPS="${OLCRTC_SEI_FPS:-60}"; SEI_BATCH="${OLCRTC_SEI_BATCH:-64}"
SEI_FRAG="${OLCRTC_SEI_FRAG:-900}"; SEI_ACK="${OLCRTC_SEI_ACK:-2000}"
# eoc srv.sh

# --- Sibling container: never overwrite an occupied slot (#481) -------------
# boc #481
# #481 was: rm -f "$NEW_NAME" followed by truncating its YAML. Reconfigure
# changes provider without renaming either resource, so the suffix is NOT
# proof that the old sibling belongs to the requested provider. Even orphaned
# YAML or a container with a missing YAML must be preserved for recovery.
NEW_NAME="${BASE_CONTAINER}-${PROVIDER}"
CONFIG_FILE="$WORK_DIR/server-${PROVIDER}.yaml"
EXISTING_NAMES=$(podman ps -a --format '{{.Names}}')
if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ] \
    || printf '%s\n' "$EXISTING_NAMES" | grep -Fxq -- "$NEW_NAME"; then
    echo "ERROR: sibling slot ${NEW_NAME} / ${CONFIG_FILE} already exists; no changes made. Manage the existing sibling instead, or explicitly remove it before adding ${PROVIDER}." >&2
    exit 1
fi
# eoc #481
echo "[*] Writing ${CONFIG_FILE} (carrier=$PROVIDER transport=$TRANSPORT room=$ROOM_ID)"
# #481: atomically reject a file created after the collision check as well.
set -o noclobber

# --- Generate the sibling YAML exactly the way srv.sh writes server.yaml -----
# boc srv.sh: "Generate YAML config" section (verbatim)
cat > "$CONFIG_FILE" <<EOF
mode: $MODE
auth:
  provider: "$PROVIDER"
EOF

if [ -n "$WB_TOKEN" ]; then
    cat >> "$CONFIG_FILE" <<EOF
  token: "$WB_TOKEN"
EOF
fi

cat >> "$CONFIG_FILE" <<EOF
room:
  id: "$ROOM_ID"
crypto:
  key: "$KEY"
net:
  transport: "$TRANSPORT"
  dns: "$DNS"
EOF

if [ "$MODE" = "srv" ] && [ -n "$SOCKS_PROXY_ADDR" ]; then
    cat >> "$CONFIG_FILE" <<EOF
socks:
  proxy_addr: "$SOCKS_PROXY_ADDR"
  proxy_port: $SOCKS_PROXY_PORT
EOF
fi

if [ "$TRANSPORT" = "vp8channel" ]; then
    cat >> "$CONFIG_FILE" <<EOF
vp8:
  fps: $VP8_FPS
  batch_size: $VP8_BATCH
EOF
fi

if [ "$TRANSPORT" = "seichannel" ]; then
    cat >> "$CONFIG_FILE" <<EOF
sei:
  fps: $SEI_FPS
  batch_size: $SEI_BATCH
  fragment_size: $SEI_FRAG
  ack_timeout_ms: $SEI_ACK
EOF
fi

if [ "$TRANSPORT" = "videochannel" ]; then
    cat >> "$CONFIG_FILE" <<EOF
video:
  width: $VIDEO_W
  height: $VIDEO_H
  fps: $VIDEO_FPS
  codec: $VIDEO_CODEC
  qr_size: $VIDEO_QR_SIZE
  qr_recovery: $VIDEO_QR_RECOVERY
  tile_module: $VIDEO_TILE_MODULE
  tile_rs: $VIDEO_TILE_RS
EOF
fi

cat >> "$CONFIG_FILE" <<EOF
debug: false
EOF
# eoc srv.sh

# --- Run the sibling ---------------------------------------------------------
# Same args as srv.sh's `podman run` (network/restart/volume/workdir/image);
# only the name and the config filename differ. Not marker-wrapped: a comment
# cannot sit inside a backslash-continued command (same note as srv.sh).
echo "[*] Starting ${NEW_NAME}..."
podman run -d \
    --name "$NEW_NAME" \
    --network host \
    --restart unless-stopped \
    -v "$WORK_DIR":/app:Z \
    -w /app \
    "$IMAGE_NAME" \
    sh -c "./olcrtc server-${PROVIDER}.yaml"

# boc srv.sh: settle before the post-start check (verbatim)
sleep 2
# eoc srv.sh

if ! podman ps --format '{{.Names}}' | grep -q "^${NEW_NAME}$" 2>/dev/null; then
    echo "[X] ${NEW_NAME} exited right after start — last log lines:"
    podman logs --tail 20 "$NEW_NAME" 2>&1 || true
    podman rm -f "$NEW_NAME" >/dev/null 2>&1 || true
    echo "ERROR: sibling container ${NEW_NAME} failed to start" >&2
    exit 1
fi

echo ""
echo "[+] Carrier added!"
echo ""
echo "Container name: $NEW_NAME"
echo "Provider:       $PROVIDER"
echo "Transport:      $TRANSPORT"
echo "Room ID/URL:    $ROOM_ID"
echo ""

# --- Emit the resulting URI (same output contract as srv.sh) -----------------
# boc srv.sh: transport payload + config-name marker + URI assembly (verbatim)
TRANSPORT_PAYLOAD=""
if [ "$TRANSPORT" = "vp8channel" ]; then
    TRANSPORT_PAYLOAD="<vp8-fps=${VP8_FPS}&vp8-batch=${VP8_BATCH}>"
elif [ "$TRANSPORT" = "seichannel" ]; then
    TRANSPORT_PAYLOAD="<fps=${SEI_FPS}&batch=${SEI_BATCH}&frag=${SEI_FRAG}&ack-ms=${SEI_ACK}>"
elif [ "$TRANSPORT" = "videochannel" ]; then
    TRANSPORT_PAYLOAD="<video-w=${VIDEO_W}&video-h=${VIDEO_H}&video-fps=${VIDEO_FPS}&video-codec=${VIDEO_CODEC}>"
    if [ "$VIDEO_CODEC" = "tile" ]; then
        TRANSPORT_PAYLOAD="<video-w=${VIDEO_W}&video-h=${VIDEO_H}&video-fps=${VIDEO_FPS}&video-codec=${VIDEO_CODEC}&video-tile-module=${VIDEO_TILE_MODULE}&video-tile-rs=${VIDEO_TILE_RS}>"
    elif [ "$VIDEO_QR_SIZE" -gt 0 ] 2>/dev/null; then
        TRANSPORT_PAYLOAD="<video-w=${VIDEO_W}&video-h=${VIDEO_H}&video-fps=${VIDEO_FPS}&video-codec=${VIDEO_CODEC}&video-qr-recovery=${VIDEO_QR_RECOVERY}&video-qr-size=${VIDEO_QR_SIZE}>"
    else
        TRANSPORT_PAYLOAD="<video-w=${VIDEO_W}&video-h=${VIDEO_H}&video-fps=${VIDEO_FPS}&video-codec=${VIDEO_CODEC}&video-qr-recovery=${VIDEO_QR_RECOVERY}>"
    fi
fi

sub_configname="${OLCRTC_CONFIG_NAME:-auto-provisioned}"

OLC_URI="olcrtc://$PROVIDER?${TRANSPORT}${TRANSPORT_PAYLOAD}@$ROOM_ID#$KEY\$$sub_configname"
echo "uri: $OLC_URI"
echo ""
echo "OLCRTC_URI=$OLC_URI"
# eoc srv.sh
echo "OLCRTC_CONTAINER=$NEW_NAME"
echo "OLCRTC_CARRIER_ADDED=ok"
