# Diagnostic messages

[Troubleshooting](setup.md#diagnose-before-changing-configuration) · [Security](../SECURITY.md)

Search the Logs view for a bracketed code such as `[OLC-1026]`, or for the
message text when no code is present. The stable client codes are defined in
`OlcCode`; not every app or Go-core log line has a code.
[OlcCode](../App/Services/OlcCode.swift) · [LogsView](../App/Views/LogsView.swift).

The table below describes **implemented code cases and emission paths**, not a
capture from a validated native run. Wording may be localized or differ by
context; use the code, timestamp, actual backend and adjacent lines together.
[Log pipeline](../App/Services/LogStore.swift) · [TunnelManager](../App/Core/TunnelManager.swift).

## Implemented client codes

| Code | Meaning | Useful next check |
|---|---|---|
| `OLC-1001` | App/session banner | Capture version and build separately. |
| `OLC-1002` | Connection attempt started | Note carrier, transport and actual backend. |
| `OLC-1003` | Native core start accepted; waiting for readiness | This is not end-to-end connectivity. |
| `OLC-1004` | Local SOCKS5 listener ready | Confirm external clients use its port and credentials. |
| `OLC-1005` | End-to-end verification probe succeeded | Read the probe target and route; one success is not universal availability. |
| `OLC-1006` | A verification probe failed | Read the error, timeout or status and neighboring probes. |
| `OLC-1007` | Initial verification accepted the connection | Do not infer throughput or UDP/IPv6 support. |
| `OLC-1009` | Tunnel verification failed after startup | Check room/key consistency, peer, carrier and transport using private test data. |
| `OLC-1010` | Keepalive probe succeeded | Check the timestamp rather than treating old success as current health. |
| `OLC-1011` | Transient keepalive failure | Look for recovery or repeated misses. |
| `OLC-1012` | Keepalive failure threshold reached | Inspect the reconnect sequence and network changes. |
| `OLC-1013` | Recovery/reconnect attempt | Note reason, attempt count and delay. |
| `OLC-1014` | Reconnect budget exhausted | Diagnose before retrying; repeated reinstall is not the first step. |
| `OLC-1015` | Waiting for network | Restore a usable path before judging carrier reachability. |
| `OLC-1026` | Configured SOCKS port is busy | Free it or update the app and client port settings together. |
| `OLC-1027` | Opt-in failover selected another protocol on the VPS | Distinguish carrier failover from Automatic's VPN-to-proxy capability fallback. |

These cases and their uses are defined by [OlcCode](../App/Services/OlcCode.swift),
[TunnelManager](../App/Core/TunnelManager.swift), [TunnelEngine](../App/Core/TunnelEngine.swift)
and the [app composition root](../App/App.swift).

## Uncoded messages and retained identifiers

Do not search for every condition as an `OLC-####` code. Latency, time-to-ready,
speed/IP checks, port checks, SSH operations and provider errors can emit plain
text. The earlier catalog reserved `OLC-1008`, `OLC-1016`–`OLC-1025` and
`OLC-2001`–`OLC-2016`; they are **not emittable cases in the current client enum**.
Do not reuse reserved IDs for unrelated meanings, or present their old catalog
entries as proof of currently prefixed runtime output.
[Current enum](../App/Services/OlcCode.swift).

Server/core logs should be searched by actual message text rather than assuming
the iOS app attaches an `OLC-2xxx` prefix. Some expected patterns include
connection/peer changes, SOCKS errors, carrier join failures and WebRTC library
diagnostics; preserve the surrounding context instead of classifying a single
line as a confirmed upstream bug.
[Core capture and filtering](../App/Services/LogStore.swift) ·
[VPS log operations](../App/Core/SSHRunner.swift).

## Interpret evidence carefully

- On a first SSH connection, learning a server key automatically is normal
  TOFU behavior, not evidence of independent identity verification. A later
  key-change warning means the connection was rejected; report whether this
  followed a server rebuild or an explicitly confirmed trust reset, without
  sharing addresses or credentials.
  [SSH trust policy](../App/Core/SSHHostKeyVerification.swift) ·
  [setup](setup.md#automatic-ssh-trust).
- An SSH trust-storage error means the saved identity could not be read or
  persisted and the connection stopped. It is not a prompt to enter a
  fingerprint manually or reset trust automatically.
  [Host-key errors](../App/Core/SSHHostKeyVerification.swift).
- A bound listener, transport-ready state and end-to-end HTTP success are
  different checkpoints. A probe can fail because of its destination as well
  as the tunnel. [Verification](../App/Core/TunnelManager.swift).
- VPN status comes from NetworkExtension; the provider also has its own
  SOCKS data-path checks. App proxy keepalive codes are not the complete VPN
  health model. [VPNController](../App/Core/VPNController.swift) ·
  [provider](../Tunnel/PacketTunnelProvider.swift) · [SOCKSDataPathProbe](../Tunnel/SOCKSDataPathProbe.swift).
- IP checks and speed tests must be interpreted with the route and capture
  time; do not label a diagnostic “direct” merely because it bypasses local
  SOCKS while a system VPN still owns routes.
  [IPChecker](../App/Services/IPChecker.swift) · [SpeedTest](../App/Services/SpeedTest.swift).
- The beam-and-firewall animation paces its particles from measured tunnel
  throughput, but it is **not a speed graph and not a health verdict**: a
  broken wall means the tunnel reported connected, nothing more.
  [SignalWaveform](../App/Views/SignalWaveform.swift).
- This catalog publishes no throughput benchmark or carrier-availability
  guarantee. Reproduce performance observations with device, network,
  build, carrier/transport, settings and methodology before drawing conclusions.

## Share a useful, safe report

Include version/build (`2.0 (2)` for this release), device/iOS, installation and
signing method, selected/actual mode, RU/EN/FR language, carrier/transport,
reproduction steps, expected/actual result and a narrow time window.
For regressions, add last known good and first known bad builds, or “unknown.”

Export only the relevant logs and inspect the result manually. The exporter
adds version/device/capture metadata; the log pipeline redacts known patterns
but cannot guarantee the removal of every secret or identifying value.
[LogExport](../App/Services/LogExport.swift) · [LogStore](../App/Services/LogStore.swift).

Remove keys, passwords, tokens, cookies, complete connection/subscription/full-
access links, QR codes, real IPs and private room IDs. Real network addresses
and exact location are not required. If safe logs are unavailable, say so rather
than exposing private data. Use the
[bug or regression form](https://github.com/Hotelk52339/olcos-ios/issues/new/choose);
send suspected vulnerabilities [privately](../SECURITY.md).
