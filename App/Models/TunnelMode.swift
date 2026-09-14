import Foundation

// MARK: - TunnelMode (#vpn)
//
// #487 was: SOCKS was the default, and a paid Developer team signature was
// described as sufficient for VPN. Actual installed-app permission/capability
// is decided lazily through the public NetworkExtension preference gate.
// TunnelMode remains the two concrete backends; preference is separate below.

enum TunnelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case proxy
    case vpn

    var id: String { rawValue }

    /// Picker label in the Config tab.
    var title: String {
        switch self {
        case .proxy: return L10n.tunnelModeProxy.localized()
        case .vpn:   return L10n.tunnelModeVPN.localized()
        }
    }
}

// boc #487: do not persist a capability-derived backend as a user's override.
// Capability is re-evaluated by each new controller/app-signature session.
enum ConnectionModePreference: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic, vpn, proxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.tunnelModeAutomatic.localized()
        case .vpn: return TunnelMode.vpn.title
        case .proxy: return TunnelMode.proxy.title
        }
    }

    var hint: String {
        switch self {
        case .automatic: return L10n.tunnelModeAutomaticHint.localized()
        case .vpn: return L10n.tunnelModeVPNHint.localized()
        case .proxy: return L10n.tunnelModeProxyHint.localized()
        }
    }

    /// Legacy persisted choices are explicit; missing/corrupt values use Auto.
    static func restored(preference: String?, legacyMode: String?) -> Self {
        if let preference { return Self(rawValue: preference) ?? .automatic }
        guard let legacyMode, let mode = TunnelMode(rawValue: legacyMode) else { return .automatic }
        return mode == .vpn ? .vpn : .proxy
    }

    /// Unknown is deliberately VPN-first, NOT a speculative downgrade.
    func effectiveMode(vpnUnavailable: Bool) -> TunnelMode {
        switch self {
        case .automatic: return vpnUnavailable ? .proxy : .vpn
        case .vpn: return .vpn
        case .proxy: return .proxy
        }
    }
}
// eoc #487
