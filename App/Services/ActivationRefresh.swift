import Foundation

// boc #485
/// Foreground checks cannot classify a route until VPN preferences have been
/// read. Keep the ordering executable in tests without loading NetworkExtension.
@MainActor
enum ActivationRefresh {
    static func run(adopt: () async -> Void,
                    isCurrent: () -> Bool,
                    refresh: () -> Void,
                    renew: () async -> Void) async {
        await adopt()
        guard !Task.isCancelled, isCurrent() else { return }
        refresh()
        guard !Task.isCancelled, isCurrent() else { return }
        await renew()
    }
}
// eoc #485
