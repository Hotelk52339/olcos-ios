# Connection links and subscriptions

[Setup](setup.md) · [Security](../SECURITY.md)

olcOS retains the `olcrtc://` and `olcrtc-sub://` schemes for compatibility;
the product rename does not create a new wire protocol.
[URL registration](../project.yml) · [URI parser](../App/Models/OlcrtcURI.swift).

**Treat all working connection links, QR codes, subscription URLs and payloads
as secrets.** A plain connection URI contains the shared room key; a full-access
share can additionally expose the VPS SSH password.
[Encoder](../App/Models/OlcrtcURI.swift) · [FullAccessShare](../App/Models/FullAccessShare.swift).

## Plain connection URI

```text
olcrtc://<carrier>?<transport>[<params>]@<roomID>#<key>[%<clientID>][$<name>]
```

Angle-bracket names above are placeholders, not literal values.
The app's encoder/parser defines these fields:
[OlcrtcURI](../App/Models/OlcrtcURI.swift).

| Field | Meaning |
|---|---|
| `carrier` | Carrier identifier, such as `telemost`, `wbstream` or `jitsi` |
| `transport` | `datachannel`, `vp8channel`, `seichannel` or `videochannel`; parsing a value does not establish runtime support |
| `[params]` | Optional transport-specific `key=value` pairs |
| `roomID` | Room identifier; may be a full room URL |
| `key` | Shared room key; connection validation expects 64 hexadecimal characters |
| `%clientID` | Optional compatible client identifier; absent means `default`, and the encoder omits `%default` |
| `$name` | Optional connection/configuration name, represented by `mimo` in the model |

Runtime constraints, including carrier combinations and VPN's rejection of
`videochannel`, apply after URI parsing.
[Connection validation](../App/Core/TunnelManager.swift) ·
[provider validation](../Tunnel/PacketTunnelProvider.swift).

### Transport parameters

The encoder writes square brackets and comma-separated parameters, for example:

```text
vp8channel[vp8-fps=15,vp8-batch=8]
seichannel[fps=30,batch=10,frag=1200,ack-ms=1]
```

The parser also accepts the server-script angle-bracket form, for example
`vp8channel<vp8-fps=15&vp8-batch=8>`. It rejects mixed bracket syntax, routes
parameter names according to transport, ignores unknown keys and handles
percent-encoded payload delimiters. The examples are syntax illustrations,
not recommended tuning or measured performance.
[Parser and encoder](../App/Models/OlcrtcURI.swift) ·
[payload tests](../Tests/OlcrtcURIPayloadTests.swift).

The URI is not a complete export of local settings, SSH trust or every
credential. SOCKS credentials and provider tokens are separate model/storage
fields; do not assume a URI preserves everything needed for every carrier.
[Connection model](../App/Models/OlcrtcConnection.swift) · [secret store](../App/Security/ConnectionSecretStore.swift).

The key is excluded from ordinary saved connection JSON, but a shared URI
contains it in plaintext. VPN startup also passes the key through system
preferences, so “the URI is the only plaintext location” would be incorrect.
[Connection encoding](../App/Models/OlcrtcConnection.swift) · [VPN configuration](../App/Models/VPNConfig.swift).

## Subscription links

```text
olcrtc-sub://<host>[:port]/<path>[?query]
```

The app replaces the scheme with `https`, preserving the host/path/query:

```text
olcrtc-sub://pool.example.org/sub
https://pool.example.org/sub
```

The payload is the upstream plain-text list format: global `#key: value`
fields, one connection URI per line and per-server `##key: value` fields.
The scheme is an iOS-client convention; the list format is documented by
[upstream](../olcrtc-upstream/docs/sub.md).

The app fetches via HTTPS and shows an import confirmation. `#name` becomes a
group, and entries use `##name` with fallback naming; unknown fields are ignored.
HTTP subscription sources are not supported, and the fetcher implements a
DoH fallback while preserving TLS host validation.
[Subscription model](../App/Models/OlcrtcSubscription.swift) ·
[fetcher](../App/Services/SubscriptionFetcher.swift).

Reimporting the same source computes additions, updates and removals using
connection identity, including the key. A changed key can therefore change
node identity; do not promise that every server-side change preserves the
same record or selection. The refresh interval is scheduling metadata, not an
always-running iOS background timer.
[Diff and refresh implementation](../App/Core/ConnectionStore.swift).

Only subscribe to operators you trust: a list update can change the
connections you use. Subscription query parameters may themselves contain
access tokens; remove the entire sensitive URL from public reports.

## Full-access host share

```text
olcrtc://host/v1/<base64url-encoded-JSON>
```

This is distinct from a plain carrier URI. The implemented payload includes
the connection URI, host label, SSH host/port/username and **SSH password**.
It is an opt-in administrative share for password-authenticated hosts, not a
private-key export or an encrypted container. The source marks the byte format
as provisional; do not advertise it as a stable upstream interchange standard.
[FullAccessShare](../App/Models/FullAccessShare.swift).

Anyone who obtains such a link may gain server administration access.
Base64url does not protect its contents. Never paste it into a public issue,
log, screenshot or online decoder. Imported credentials are not proof of host
identity: SSH uses automatic first-use trust on the receiving device and checks
saved keys on later connections. A changed key is rejected until trust is
explicitly reset with confirmation.
[SSH trust policy](../App/Core/SSHHostKeyVerification.swift).
