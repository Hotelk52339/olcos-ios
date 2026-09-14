import Foundation

// MARK: - VPNConfig (#vpn)
//
// The tunnel configuration handed from the main app to the packet-tunnel
// extension. Compiled into BOTH targets (olcrtc-ios and olcrtc-tunnel — the
// extension target lists this file explicitly in project.yml), and carried
// across the process boundary inside
// NETunnelProviderProtocol.providerConfiguration.
//
// providerConfiguration is a plist/JSON dictionary persisted by the system
// into the VPN configuration store, so every value here is limited to
// String / Int / Bool (enforced by the round-trip helpers below). No App
// Group and no keychain sharing is involved in v1 — which also means keyHex
// and wbToken ride the system VPN preferences; an accepted trade-off of the
// minimal-signing-surface decision (vpn-impl-decisions.md).
//
// vp8FPS / vp8Batch mirror OlcrtcConnection's per-connection overrides:
// nil = "let the Go core use its own defaults" (30 / 64, mobile/config.go),
// so the extension never needs SettingsStore. waitReadyTimeoutMs = 0 likewise
// defers to the core's default ready timeout (8 s, mobile/runtime.go).

struct VPNConfig: Codable, Equatable, Sendable {

    /// Loopback SOCKS5 port the core binds INSIDE the extension process.
    /// Fixed and private to the extension — unrelated to proxy mode's port.
    static let defaultSocksPort = 18080

    var carrier:   String        // MobileRuntime.setProvider — jitsi | telemost | wbstream | none
    var transport: String        // setTransport — datachannel | vp8channel | seichannel (videochannel is rejected in VPN mode)
    var roomID:    String        // setRoom — room ID or URL, verbatim
    var clientID:  String        // setDeviceID
    var keyHex:    String        // setKey — 64-char hex (32 bytes)
    var dns:       String        // setDNS — "host:port", e.g. "8.8.8.8:53"
    var vp8FPS:    Int?          // setVP8Options (vp8channel only); nil = core default
    var vp8Batch:  Int?          // setVP8Options (vp8channel only); nil = core default
    var seiFPS:    Int           // setSEIOptions (seichannel only)
    var seiBatch:  Int
    var seiFrag:   Int
    var seiACK:    Int
    var wbToken:   String        // setProviderToken — empty for non-wbstream carriers
    var waitReadyTimeoutMs: Int  // Runtime.waitReady; 0 = core default (8 s)
    var socksPort: Int           // in-extension loopback SOCKS port (defaultSocksPort)
    // boc #470: the resolver the OS is handed (NEDNSSettings) — "host:port",
    // same shape as `dns`. They differ in WHERE the query is answered from:
    // `dns` is the core's own resolver, dialled from the PHONE (provider-process
    // sockets bypass the tunnel), while the OS's DNS rides the default route
    // THROUGH the tunnel and is dialled by the olcrtc SERVER. The Russian-
    // carrier presets (AppConstants.ruCarrierDnsPresets, "resolve only from
    // inside the carrier's network") are right for the first and unreachable
    // for the second: MTS + VPN mode reported "Connected" while every hostname
    // on the device failed to resolve. The bridge init substitutes a public
    // resolver here for those; every other choice passes through unchanged.
    var systemDNS: String
    // eoc #470

    /// DNS server host with the port stripped, for NEDNSSettings(servers:).
    /// Handles "8.8.8.8:53", bracketed IPv6 "[2001:db8::1]:53", and a bare
    /// host with no port.
    var dnsHost: String { Self.host(of: dns) }   // #470: shared helper

    /// #470: `systemDNS` with the port stripped — what `NEDNSSettings` takes.
    var systemDNSHost: String { Self.host(of: systemDNS) }

    // boc #484: the packet pump deliberately drops IPv6; never install an IPv6
    // OS resolver, including a profile saved by an older build. Keep the core's
    // `dns` untouched: its provider-owned sockets use the underlying interface.
    // Fail closed rather than silently replacing a user's resolver/privacy policy.
    var supportsPacketDNS: Bool { Self.supportsPacketDNS(systemDNS) }

    static func supportsPacketDNS(_ resolver: String) -> Bool {
        let value = resolver.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && parts[1] == "53") else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        // NEDNSSettings requires IP literals and offers no custom port. Reject
        // names too: resolving one could bootstrap via an unsupported IPv6 path.
        return octets.count == 4 && octets.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil
        }
    }
    // eoc #484

    /// #470: the `dnsHost` rule, factored so both resolvers use it.
    static func host(of dns: String) -> String {
        let raw = dns.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("["), let close = raw.firstIndex(of: "]") {
            return String(raw[raw.index(after: raw.startIndex)..<close])
        }
        // A lone colon separates host:port; multiple colons without brackets
        // mean a bare IPv6 host (no port to strip).
        let parts = raw.split(separator: ":")
        if parts.count == 2, let first = parts.first { return String(first) }
        return raw
    }

    // MARK: Construction

    /// #470: `systemDNS` is last so every existing call keeps its argument
    /// order; nil ⇒ the same resolver as `dns`.
    init(carrier: String, transport: String, roomID: String, clientID: String,
         keyHex: String, dns: String, vp8FPS: Int? = nil, vp8Batch: Int? = nil,
         seiFPS: Int = 30, seiBatch: Int = 10, seiFrag: Int = 1200, seiACK: Int = 1,
         wbToken: String = "", waitReadyTimeoutMs: Int = 0,
         socksPort: Int = VPNConfig.defaultSocksPort,
         systemDNS: String? = nil) {
        self.carrier   = carrier
        self.transport = transport
        self.roomID    = roomID
        self.clientID  = clientID
        self.keyHex    = keyHex
        self.dns       = dns
        self.vp8FPS    = vp8FPS
        self.vp8Batch  = vp8Batch
        self.seiFPS    = seiFPS
        self.seiBatch  = seiBatch
        self.seiFrag   = seiFrag
        self.seiACK    = seiACK
        self.wbToken   = wbToken
        self.waitReadyTimeoutMs = waitReadyTimeoutMs
        self.socksPort = socksPort
        self.systemDNS = systemDNS ?? dns   // #470
    }

    // App-target-only bridge. OlcrtcConnection is NOT compiled into the
    // olcrtc-tunnel target (it would drag OlcrtcURI → L10n/SettingsStore/
    // LogStore along), so project.yml must add OLCRTC_TUNNEL_EXTENSION to the
    // tunnel target's SWIFT_ACTIVE_COMPILATION_CONDITIONS to exclude this
    // init there. The extension only ever uses init?(providerConfiguration:).
    #if !OLCRTC_TUNNEL_EXTENSION
    /// Builds the extension config from a saved connection. `key`/`wbToken`
    /// must already be restored from ConnectionSecretStore (they are Keychain-
    /// only and never ride OlcrtcConnection's own Codable form).
    ///
    /// `fallbackVP8FPS`/`fallbackVP8Batch` are the app-global values (from
    /// SettingsStore); the per-connection overrides win, matching
    /// OlcrtcEngine's `params.vp8FPS ?? settings.vp8FPS` resolution. Leaving
    /// them nil defers to the Go core's own defaults.
    init(from connection: OlcrtcConnection, dns: String, timeoutMs: Int,
         socksPort: Int = VPNConfig.defaultSocksPort,
         fallbackVP8FPS: Int? = nil, fallbackVP8Batch: Int? = nil) {
        self.init(
            carrier:   connection.carrier,
            transport: connection.transport,
            roomID:    connection.roomID,
            clientID:  connection.clientID,
            keyHex:    connection.key,
            dns:       dns,
            vp8FPS:    connection.vp8FPS       ?? fallbackVP8FPS,
            vp8Batch:  connection.vp8BatchSize ?? fallbackVP8Batch,
            seiFPS:    connection.seiFPS,
            seiBatch:  connection.seiBatch,
            seiFrag:   connection.seiFrag,
            seiACK:    connection.seiACK,
            wbToken:   connection.wbToken,
            waitReadyTimeoutMs: timeoutMs,
            socksPort: socksPort,
            systemDNS: Self.systemResolver(for: dns))   // #470
    }

    /// #470: the resolver the OS may use THROUGH the tunnel. A carrier-internal
    /// preset (answerable only from inside that carrier's network) cannot be
    /// reached from the VPS the tunnel exits at, so it becomes the app's
    /// default public resolver; anything else is the user's own choice and
    /// stays. Compared by host, so a hand-typed preset without a port matches.
    static func systemResolver(for dns: String) -> String {
        let chosen = host(of: dns)
        let carrierInternal = AppConstants.ruCarrierDnsPresets.contains { host(of: $0.value) == chosen }
        return carrierInternal ? SettingsStore.Defaults.dnsServer : dns
    }
    #endif

    // MARK: providerConfiguration round-trip

    /// One shared key set for Codable AND the providerConfiguration dict, so
    /// the two serialisations can never drift.
    private enum CodingKeys: String, CodingKey {
        case carrier, transport, roomID, clientID, keyHex, dns
        case vp8FPS, vp8Batch
        case seiFPS, seiBatch, seiFrag, seiACK
        case wbToken, waitReadyTimeoutMs, socksPort
        case systemDNS   // #470
    }

    /// Plist/JSON-safe dictionary for NETunnelProviderProtocol
    /// .providerConfiguration. Values are String/Int only; nil vp8 overrides
    /// are omitted entirely (absence = core default).
    /// #470: the two `providerConfiguration` entries that carry a secret. The
    /// app blanks them in the SAVED profile once a session ends (VPNController),
    /// so the room key and the WB token do not sit in the system's VPN
    /// preferences between sessions; `start()` writes them again every launch.
    static let secretConfigKeys: [String] = [CodingKeys.keyHex.rawValue,
                                             CodingKeys.wbToken.rawValue]

    func providerConfiguration() -> [String: Any] {
        var dict: [String: Any] = [
            CodingKeys.carrier.rawValue:   carrier,
            CodingKeys.transport.rawValue: transport,
            CodingKeys.roomID.rawValue:    roomID,
            CodingKeys.clientID.rawValue:  clientID,
            CodingKeys.keyHex.rawValue:    keyHex,
            CodingKeys.dns.rawValue:       dns,
            CodingKeys.seiFPS.rawValue:    seiFPS,
            CodingKeys.seiBatch.rawValue:  seiBatch,
            CodingKeys.seiFrag.rawValue:   seiFrag,
            CodingKeys.seiACK.rawValue:    seiACK,
            CodingKeys.wbToken.rawValue:   wbToken,
            CodingKeys.waitReadyTimeoutMs.rawValue: waitReadyTimeoutMs,
            CodingKeys.socksPort.rawValue: socksPort,
            CodingKeys.systemDNS.rawValue: systemDNS,   // #470
        ]
        if let vp8FPS   { dict[CodingKeys.vp8FPS.rawValue]   = vp8FPS }
        if let vp8Batch { dict[CodingKeys.vp8Batch.rawValue] = vp8Batch }
        return dict
    }

    /// Rebuilds the config in the extension process. Returns nil when any
    /// required field is missing or mistyped (the provider then fails
    /// startTunnel with .configurationInvalid). Numeric values come back from
    /// the system as NSNumber; `as? Int` bridges them.
    init?(providerConfiguration dict: [String: Any]) {
        guard
            let carrier   = dict[CodingKeys.carrier.rawValue]   as? String,
            let transport = dict[CodingKeys.transport.rawValue] as? String,
            let roomID    = dict[CodingKeys.roomID.rawValue]    as? String,
            let clientID  = dict[CodingKeys.clientID.rawValue]  as? String,
            let keyHex    = dict[CodingKeys.keyHex.rawValue]    as? String,
            let dns       = dict[CodingKeys.dns.rawValue]       as? String
        else { return nil }
        self.init(
            carrier:   carrier,
            transport: transport,
            roomID:    roomID,
            clientID:  clientID,
            keyHex:    keyHex,
            dns:       dns,
            vp8FPS:    dict[CodingKeys.vp8FPS.rawValue]   as? Int,
            vp8Batch:  dict[CodingKeys.vp8Batch.rawValue] as? Int,
            seiFPS:    dict[CodingKeys.seiFPS.rawValue]   as? Int ?? 30,
            seiBatch:  dict[CodingKeys.seiBatch.rawValue] as? Int ?? 10,
            seiFrag:   dict[CodingKeys.seiFrag.rawValue]  as? Int ?? 1200,
            seiACK:    dict[CodingKeys.seiACK.rawValue]   as? Int ?? 1,
            wbToken:   dict[CodingKeys.wbToken.rawValue]  as? String ?? "",
            waitReadyTimeoutMs: dict[CodingKeys.waitReadyTimeoutMs.rawValue] as? Int ?? 0,
            socksPort: dict[CodingKeys.socksPort.rawValue] as? Int ?? VPNConfig.defaultSocksPort,
            // #470: absent in a profile saved by an older build ⇒ same as `dns`.
            systemDNS: dict[CodingKeys.systemDNS.rawValue] as? String)
    }
}

// boc #484: shared with the extension and app test target without another
// generated-project source entry. Pure policy/wire checks need no live network.
struct VPNDataPathHealth {
    static let interval: TimeInterval = 20
    static let timeout: TimeInterval = 15
    static let startupGrace: TimeInterval = 45
    static let failureLimit = 3
    private(set) var failures = 0

    mutating func record(success: Bool) -> Bool {
        failures = success ? 0 : min(failures + 1, Self.failureLimit)
        return failures >= Self.failureLimit
    }

    // Root NS question: tiny, independent of a third-party HTTP endpoint.
    static func dnsQuery(id: UInt16) -> Data {
        Data([UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
              0, 0, 2, 0, 1])
    }

    static func validDNSResponse(_ data: Data, id: UInt16) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 17, bytes.count <= 4096,
              bytes[0] == UInt8(id >> 8), bytes[1] == UInt8(id & 255),
              bytes[2] & 0x80 != 0, bytes[2] & 0x78 == 0,
              bytes[4] == 0, bytes[5] == 1 else { return false }
        // Even SERVFAIL/REFUSED proves the bidirectional data path; this is a
        // reachability watch, not a claim that every DNS name can be resolved.
        return Array(bytes[12..<17]) == [0, 0, 2, 0, 1]
    }
}
// eoc #484
