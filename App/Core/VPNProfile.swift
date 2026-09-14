import Foundation
import NetworkExtension

// boc #483: inject the OS boundary, not synthetic TunnelManager states. Unit
// tests can suspend every preference/stop operation without invoking NE or Go.
@MainActor
protocol VPNProfile: AnyObject {
    var providerIdentifier: String? { get }
    var status: VPNController.Status { get }
    var configuration: [String: Any] { get set }
    func configure(_ config: VPNConfig)
    func save() async throws
    func reload() async throws
    func start() throws
    func stop()
    func observe(_ changed: @escaping @MainActor () -> Void)
    func disconnectError() async -> String?
    func message(_ data: Data) async -> Data?
}

@MainActor
final class SystemVPNProfile: VPNProfile {
    let manager: NETunnelProviderManager
    private var observer: NSObjectProtocol?

    init(_ manager: NETunnelProviderManager = NETunnelProviderManager()) {
        self.manager = manager
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var providerIdentifier: String? {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
    }
    var status: VPNController.Status { .init(manager.connection.status) }
    var configuration: [String: Any] {
        get { (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:] }
        set {
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return }
            proto.providerConfiguration = newValue
            manager.protocolConfiguration = proto
        }
    }

    func configure(_ config: VPNConfig) {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = VPNController.providerBundleIdentifier
        proto.serverAddress = config.roomID.isEmpty ? "olcrtc" : config.roomID
        // boc #487: provider-localized errors follow the app's selected language,
        // not a potentially different system language. This is not a secret.
        // #487 was: proto.providerConfiguration = config.providerConfiguration()
        var providerConfiguration = config.providerConfiguration()
        providerConfiguration["uiLanguage"] = AppLocale.current.rawValue
        proto.providerConfiguration = providerConfiguration
        // eoc #487
        manager.protocolConfiguration = proto
        manager.localizedDescription = L10n.vpnSettingsEntryName.localized()
        manager.isEnabled = true
    }
    func save() async throws { try await manager.saveToPreferences() }
    func reload() async throws { try await manager.loadFromPreferences() }
    func start() throws { try manager.connection.startVPNTunnel(options: nil) }
    func stop() { manager.connection.stopVPNTunnel() }

    func observe(_ changed: @escaping @MainActor () -> Void) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { _ in
            Task { @MainActor in changed() }
        }
    }

    func disconnectError() async -> String? {
        await withCheckedContinuation { continuation in
            manager.connection.fetchLastDisconnectError { error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
    }

    func message(_ data: Data) async -> Data? {
        guard let session = manager.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
// eoc #483
