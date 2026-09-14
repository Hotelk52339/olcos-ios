# Setup and connection modes

[Overview](../README.md) · [Build](build.md) · [Security](../SECURITY.md)

## Before you start

Use an iPhone or iPad with iOS/iPadOS 17+, an internet connection and either a
trusted olcrtc connection or a Linux VPS you control.
The iOS app can provision a server over SSH or import existing connection
details. [Project](../project.yml) · [provisioning](../App/Core/Provisioning.swift) · [URI guide](uri.md).

Review the contents and verification notes of the selected
[release](https://github.com/Hotelk52339/olcos-ios/releases), or
[build from source](build.md). A release tag, unsigned IPA or attractive
preview is not proof that a signed installation can run a VPN.
Do not provide Apple ID credentials, signing certificates or private keys to
issue reporters or unknown build services.

VPN requires valid NetworkExtension capabilities in the installed app and
extension, plus iOS permission. A paid developer account by itself is not
runtime proof; re-signing tools may alter entitlements.
The app checks the public NE preference operations and actual session state.
[VPNController](../App/Core/VPNController.swift) · [entitlements](../App/Entitlements.plist).

## Choose a connection mode

| Preference | Intended behavior | Routing scope |
|---|---|---|
| **Automatic** | VPN-first. Switches to SOCKS5 only when NE permission/capability is recognized as unavailable and cleanup completes. | Check the actual backend; fallback is proxy-only. |
| **VPN** | Requests the system packet tunnel; a failure stays a failure, not a silent proxy downgrade. | Supported device packet traffic, subject to the restrictions below. |
| **SOCKS5** | Starts the local core/proxy in the app process. | Only clients explicitly configured to use that proxy. |

The preference and active backend are separate state in the
[mode policy](../App/Models/TunnelMode.swift) and [TunnelManager](../App/Core/TunnelManager.swift).

A bad room key, unreachable carrier, unsupported DNS setting or failed
handshake must not be diagnosed as proof that your installation lacks VPN
permission. Automatic is not a general “try anything after any error” setting.
[Fallback classification](../App/Core/VPNController.swift).

For SOCKS5-aware clients, use `127.0.0.1`, the configured port and any enabled
local SOCKS credentials. Changing the configured port also requires updating
those clients; a busy port fails rather than being silently replaced.
The VPN extension has its own loopback listener, not the app's configurable
proxy endpoint. [TunnelManager](../App/Core/TunnelManager.swift) · [VPNConfig](../App/Models/VPNConfig.swift).

## Import an existing connection

Paste or scan a trusted `olcrtc://` link, or open an `olcrtc-sub://` subscription
and inspect the confirmation before importing. A connection URI contains a room
key; subscription lists can distribute many such keys.
The distinct full-access format can also include an SSH password.
[Formats and import behavior](uri.md).

Never attach working URIs, subscription tokens or QR codes to a public issue.
Connecting through a server grants that server a role in your traffic path;
only import configurations from parties you trust.

## Prepare your own VPS

The bundled installer uses a Linux host, package tools and Podman to build/run
the upstream server; installation changes the host and can replace existing
`olcrtc-server-*` containers and old deploy directories.
Use a dedicated/test VPS first, inspect the script and back up relevant server
configuration before reinstalling. Do not treat reinstall as a harmless
connectivity diagnostic. [Installer](../scripts/srv.sh).

1. Obtain the host, SSH port, account and authentication material through your
   VPS provider's trusted administration channel. Ensure the account has the
   permissions needed for the operations you intend to run.
2. Add the host in olcOS and enter the SSH authentication details. No manual
   host-key fingerprint entry or verification checklist is required: the first
   connection automatically records the server key for that host and port.
   [Host editor](../App/Views/AddServerHostView.swift) ·
   [SSH trust policy](../App/Core/SSHHostKeyVerification.swift).
3. Choose a carrier, transport and room identifier; the current UI requires a
   room for every carrier. Treat the built-in compatibility matrix as a
   configuration guide, not a live availability test.
   [Carrier choices](../App/Utilities/CarrierTransportMatrix.swift).
4. Review the installation action, run it, inspect the returned connection and
   connect using your chosen mode. Provisioning is separate from the packet
   path. [SSHRunner](../App/Core/SSHRunner.swift) · [architecture](architecture.md).

### Automatic SSH trust

olcOS uses **trust on first use (TOFU)**: it automatically remembers the first
server key for the original host and SSH port, then compares the presented
key on subsequent connections. There is no fingerprint to copy into a form.
First use establishes trust; it does not independently authenticate the
server's identity, so begin on a connection you trust.
[Host-key policy](../App/Core/SSHHostKeyVerification.swift).

If the key changes, olcOS warns and rejects the connection rather than silently
replacing the saved key. An expected rebuild or key rotation can be handled by
explicitly confirming a reset of saved trust, then connecting again to learn
the next key. Cancel the reset if the change is unexpected; routine timeouts
are not a reason to reset trust.
[Host editor](../App/Views/AddServerHostView.swift) ·
[SSH connection handling](../App/Core/SSHRunner.swift).

SSH may use a local SOCKS relay when proxy mode is active, or dial through
normal OS routing; failed relay attempts can fall back directly. A running VPN
also affects normal OS routing. Trust remains bound to the original VPS
host and port, not the relay's temporary localhost endpoint.
[SSH routing](../App/Core/SSHRunner.swift).

## VPN limitations

- IPv4 TCP is forwarded. UDP DNS receives a truncated response to trigger
  TCP retry; other UDP is dropped. Apps that can retry over TCP may work, but
  UDP-only protocols will not. [tunstack](../gomobile/tunstack/tunstack.go).
- IPv6 packets are captured and dropped, not forwarded or intentionally
  released to a direct route. This is not IPv6 connectivity support.
  [Packet pump](../Tunnel/PacketTunnelProvider.swift).
- `videochannel` is rejected in VPN mode; the provider enforces its memory
  boundary. `datachannel`, `vp8channel` and `seichannel` still depend on the
  chosen carrier and its current availability.
  [Provider validation](../Tunnel/PacketTunnelProvider.swift).
- System DNS must be an IPv4 literal with port 53. The core's own resolver and
  the OS resolver have different routes; known carrier-internal DNS presets are
  mapped to a public system resolver by the configuration bridge.
  Unsupported system DNS is rejected rather than silently bypassing the tunnel.
  [DNS policy](../App/Models/VPNConfig.swift).
- Start sessions from olcOS. Once profile secrets are cleared after stopping,
  a cold start from iOS Settings cannot hydrate them and is rejected.
  [Startup and cleanup](../App/Core/VPNController.swift) ·
  [provider guard](../Tunnel/PacketTunnelProvider.swift).

The app's proxy background keeper and the independently running extension are
different lifecycle mechanisms; neither is evidence of unlimited background
uptime on every device. Test lock/unlock, network changes and recovery on your
signed installation. [Background keeper](../App/Services/BackgroundRuntimeKeeper.swift) ·
[provider](../Tunnel/PacketTunnelProvider.swift).

## Diagnose before changing configuration

Record version/build, selected and actual mode, signing method, iOS/device,
language and carrier/transport. Note whether the failure follows a network
change, lock/unlock, foreground return or an explicit disconnect.
Compare a real diagnostic result with its route and timestamp; the animated
waveform is decorative, not a packet or speed measurement.
[Diagnostic guide](diagnostic-messages.md) · [motion policy](../App/Views/SignalWaveform.swift).

Use the [bug/regression forms](https://github.com/Hotelk52339/olcos-ios/issues/new/choose)
with sanitized logs. Real IPs, exact locations and credentials are not required.
Report suspected vulnerabilities [privately](../SECURITY.md).
