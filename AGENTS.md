# olcOS — technical contract

Read [CONTRIBUTING.md](CONTRIBUTING.md), [architecture](docs/architecture.md) and
[build instructions](docs/build.md) before changing the relevant subsystem.
Code and executable tests take precedence over historical comments.

## Identity and compatibility

- Public brand: **olcOS**. Repository: `Hotelk52339/olcos-ios`.
- Release identity: marketing version `1.0`, build `1`, tag `v1.0.1`.
  Version changes belong to the release owner; do not bump per contribution.
- Preserve bundle IDs and storage keys as well as URI compatibility.
- Preserve technical targets/schemes/modules `olcrtc-ios`, `olcrtc-ios-tests`
  and `olcrtc-tunnel`, plus the `olcrtc://` and `olcrtc-sub://` wire formats unless
  an explicitly reviewed migration changes them. [Project](project.yml) ·
  [URI contract](docs/uri.md).
- This is the iOS/iPadOS 17+ codebase; Android, Windows and macOS are plans, not
  shipping clients. Do not use macOS build tooling as evidence of a macOS app.

## Change discipline

- Keep changes focused. Explain non-obvious decisions; remove obsolete code
  when appropriate instead of preserving every replacement as a comment.
- No task-number markers or private tracker references are required. Existing
  historical markers do not establish a public contribution convention.
- **Exception:** preserve the machine-checked `boc/eoc olcrtc-ios` and rejected
  upstream blocks in `scripts/srv.sh`, plus the parity blocks in related scripts.
  These are executable maintenance contracts, not general comment style.
  [Parity checker](scripts/parity_check.py) · [script tests](Tests/ServerScriptParityTests.swift).
- Use factual Conventional Commits: `fix(vpn): serialize profile cleanup`.
  Do not attribute commits to an AI, prompt, conversation or user request.
- Follow the owner's authorization for commits, pushes and releases. Do not
  publish without authorization; explicit authorization is not overridden by
  a blanket prohibition in this file.
- Preserve the project [LICENSE](LICENSE), upstream's
  [WTFPL](olcrtc-upstream/LICENSE) and applicable dependency notices.

## Architecture and security invariants

- `project.yml` is authoritative; generate the Xcode project and configured
  plists with XcodeGen. Do not hand-fix generated output. Build upstream mobile
  and local tunstack in **one** gomobile framework, not two Go runtimes.
  [Project](project.yml) · [framework build](scripts/build-framework.sh).
- Keep SwiftUI ownership explicit, blocking engine work off the main actor,
  settings snapshots consistent and lifecycle continuations guarded by
  cancellation/attempt epochs. Never let a stale operation reconnect after a
  user disconnect. [Composition root](App/App.swift) · [TunnelManager](App/Core/TunnelManager.swift).
- Preserve user mode preference separately from actual backend. Automatic
  downgrades only on typed NE permission/capability evidence and after joined
  stop/secret-cleanup barriers; explicit VPN must not silently become SOCKS5.
  [Mode policy](App/Models/TunnelMode.swift) · [controller](App/Core/VPNController.swift).
- VPN state follows the OS, not proxy timers. Retain save → reload → start
  ordering, existing-tunnel adoption and serialized stop/profile cleanup.
  [VPNProfile](App/Core/VPNProfile.swift) · [VPNController](App/Core/VPNController.swift).
- Do not widen packet support by leaking unsupported traffic: IPv6 is captured
  and dropped; UDP is not forwarded except the DNS truncation mechanism.
  Reject VPN `videochannel` and unsupported system DNS before routes start.
  Never describe these controls as a universal kill switch.
  [Provider](Tunnel/PacketTunnelProvider.swift) · [tunstack](gomobile/tunstack/tunstack.go).
- SSH uses endpoint-bound TOFU: automatically remember the first key for the
  original host and port, including SOCKS relay attempts, then require a match.
  Reject changed keys; only an explicit, confirmed trust reset may permit
  learning a replacement on reconnect. Do not restore mandatory manual
  fingerprint entry, silently replace keys or describe first use as independent
  identity verification. SSH's direct retry is not a tunnel-only guarantee.
  [Verification](App/Core/SSHHostKeyVerification.swift) · [SSHRunner](App/Core/SSHRunner.swift).
- Persist first-use trust before accepting the key. Trust belongs to the
  endpoint, not a model UUID; removing/recreating a host is not a trust reset.
  Trust-store read/write failures stop the connection rather than accepting
  an unrecorded key. [SSH trust implementation](App/Core/SSHHostKeyVerification.swift).
- Keep connection and SSH secrets out of UserDefaults, logs, fixtures and
  public reports. Do not claim VPN secrets never enter system preferences;
  cleanup can fail. Preserve unreadable saved data during recovery.
  [Secret store](App/Security/ConnectionSecretStore.swift) ·
  [connection store](App/Core/ConnectionStore.swift) · [security policy](SECURITY.md).
- Keep `L10n` keys, formatting placeholders and RU/EN/FR translations aligned,
  including extension resources. Decorative waveform motion is active/visible/
  connected-only, respects Reduce Motion and is never a traffic metric.
  Haptics must not repeat on automatic recovery or foreground adoption.
  [Localization](App/Localization/L10n.swift) · [interaction policy](App/Views/SignalWaveform.swift).

## Verification contract

For each relevant check, report **PASS**, **FAIL**, **NOT RUN** or
**NOT APPLICABLE**, with the exact command, environment and result/evidence.
Do not turn a source review, successful YAML parse, mock test or simulator build
into a claim of native device/VPN validation.

Minimum selection:

| Change | Evidence to gather |
|---|---|
| Documentation/forms | Links, image paths, form YAML, consistency with implementation |
| Swift/model/localization | Relevant XCTest suite; build/lint when available |
| Lifecycle or security | Focused cancellation, routing, host-key, storage and redaction regressions |
| VPN/tunstack | Go checks, Swift tests/build, then signed-device packet and lifecycle checks |
| Server scripts | Parity, syntax, relevant Python/Swift script tests; isolated VPS test when needed |
| UI | Native render evidence, RU/EN/FR, accessibility/Reduce Motion, real-device haptics as applicable |

Use the runnable commands in [docs/build.md](docs/build.md). A missing toolchain
is **NOT RUN**, not a passing build. CI configuration describes intended checks;
only an actual run supplies results. [CI definition](.github/workflows/ci.yml).
