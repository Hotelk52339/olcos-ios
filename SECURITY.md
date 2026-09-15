# olcOS security policy

## Report privately

**Do not open a public issue or pull request containing an unpatched
vulnerability, exploit details or secrets.**

Use GitHub's enabled **[private vulnerability reporting](https://github.com/Hotelk52339/olcos-ios/security/advisories/new)**.
Begin with a brief summary in the private report and agree on a suitable
transfer method before sending sensitive material. Do not send production
credentials or substitute a public issue.

Include:

- Affected version **and build** (for example `2.0 (2)`), iOS version,
  device class, installation/signing method and actual backend.
- Impact, prerequisites and minimal steps using synthetic/test data.
- Carrier/transport and relevant network conditions, without real IPs,
  private room IDs or identifying provider/account details.
- A sanitized log excerpt or minimal proof of concept; specify what you
  observed versus what you infer, and whether the issue reproduces consistently.
- Whether you can help validate a fix and a preferred contact method.

Allow time to investigate and coordinate disclosure before publishing details.
Do not test against other people's devices, accounts, VPS instances or carrier
infrastructure without permission. No response deadline, bounty or resolution
SLA is promised.

## Scope and supported line

This policy covers the **olcOS 2.0 iOS codebase**, including app integration,
the packet-tunnel extension, local proxy, SSH provisioning, imports, storage
and diagnostic exports. [Project](project.yml) · [architecture](docs/architecture.md).
No security-maintenance commitment is made here for older builds or planned
Android, Windows and macOS clients.

Report routing leaks, authentication bypasses, secret exposure, unsafe script
construction, host-key validation defects and misleading security state.
If a defect is in the underlying core, coordinate with
[upstream olcrtc](https://github.com/openlibrecommunity/olcrtc) through its own
security guidance; do not publish it to upstream's ordinary issue tracker.
For uncertain ownership, start with the private reporting channel above.

## Security boundaries, not guarantees

### SSH trust and administration

SSH uses **trust on first use (TOFU)**. The first server key is remembered
automatically for the original host and port, including connections through
a local SOCKS relay; later connections compare against that saved key.
No manual fingerprint entry or independent-verification checklist is required.
[SSHHostKeyVerification](App/Core/SSHHostKeyVerification.swift) ·
[SSHRunner](App/Core/SSHRunner.swift).

**Initial trust is the limitation:** TOFU cannot detect an impersonator already
present on the first connection. It checks continuity afterward, not independent
ownership of the first key. Start on a connection you trust.

A changed key triggers a warning and rejects the connection. An expected
server rebuild or key rotation requires explicit confirmation to reset saved
trust before reconnecting; the next connection establishes trust again.
Unexpected changes should not be dismissed, and keys are never silently
replaced during a retry. [Host-key policy](App/Core/SSHHostKeyVerification.swift) ·
[reset interface](App/Views/ServerAdvancedView.swift) (shown on “Manage server”
only after a mismatch) · [trust store](App/Core/SSHHostKeyTrustStore.swift).

The SSH route can retry directly when a relay is unavailable: **SSH management
is not guaranteed to remain inside olcOS**, although the same host-key
continuity check still applies. [SSH transport](App/Core/SSHTransport.swift) · [dial policy](App/Core/SSHRunner.swift).

### Traffic routing

SOCKS5 mode covers explicitly configured clients, not every app.
Automatic starts VPN-first and permits SOCKS5 fallback only for recognized
NE permission/capability failures after stop/cleanup, not ordinary network,
carrier or key failures. Explicit VPN never silently downgrades.
[TunnelManager](App/Core/TunnelManager.swift) · [mode policy](App/Models/TunnelMode.swift).

The VPN packet path carries IPv4 TCP. IPv6 is captured and dropped;
UDP DNS is truncated to encourage TCP retry and other UDP is dropped.
Provider-originated sockets use the underlying network; `includeAllNetworks`
is deliberately not enabled. These are implementation boundaries, **not a
guarantee that no traffic can ever leave directly**.
[PacketTunnelProvider](Tunnel/PacketTunnelProvider.swift) · [tunstack](gomobile/tunstack/tunstack.go).

There is no universal kill-switch, anonymity, carrier invisibility or
unblockability claim. Consider traffic before connection, after disconnection,
during OS failure and outside configured proxy clients. The VPS, carrier,
resolver and destination remain separate trust boundaries.

### Secrets at rest and in transit

Persistent connection secrets use Keychain; the helper requests
`AfterFirstUnlockThisDeviceOnly`. Connection keys, SOCKS passwords and provider
tokens are excluded from the connection model's ordinary encoded form.
[KeychainHelper](App/Security/KeychainHelper.swift) ·
[ConnectionSecretStore](App/Security/ConnectionSecretStore.swift) ·
[OlcrtcConnection](App/Models/OlcrtcConnection.swift).

**VPN is an explicit exception to a “Keychain only” claim.** During startup and
the session, the room key and provider token pass through
`providerConfiguration` in system VPN preferences. The controller attempts to
blank them after the tunnel is down and serializes cleanup with future starts;
a failed preference save or interrupted cleanup can leave persisted secrets.
There is no shared-Keychain/App-Group handoff here.
[VPNConfig](App/Models/VPNConfig.swift) · [VPNController](App/Core/VPNController.swift).

After successful cleanup, start a new session from the app; a cold start from
iOS Settings cannot recover those cleared credentials and is rejected.
Do not keep plaintext profile secrets merely to enable external restart.
[Provider startup validation](Tunnel/PacketTunnelProvider.swift).

Connection URIs and QR codes expose the room key. A full-access share can also
contain the VPS SSH password; base64url is encoding, not encryption.
Treat subscription URLs and exported configuration as sensitive too.
[URI guide](docs/uri.md) · [FullAccessShare](App/Models/FullAccessShare.swift).

### Logs and diagnostics

The app implements log redaction, but no pattern-based filter can guarantee
that every secret or identifier is removed. Inspect exports and screenshots
before sharing; remove real IPs, full URIs, QR codes, credentials, room IDs,
subscription tokens and identifying account data.
[LogStore](App/Services/LogStore.swift) · [LogExport](App/Services/LogExport.swift).

The hero picture (beam and stone wall) is not evidence that packets are
flowing, a speed measurement or a security indicator, even though its pace
follows measured tunnel throughput. Use actual diagnostic results with their
route and timestamp, and do not infer universal connectivity from one success.
[Motion policy](App/Views/SignalWaveform.swift) · [diagnostics](docs/diagnostic-messages.md).

The project makes no claim to protect a compromised/jailbroken device,
malicious VPS, stolen account or untrusted third-party carrier. These limits
do not make a reproducible app defect unreportable.
