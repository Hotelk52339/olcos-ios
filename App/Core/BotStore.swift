import Foundation

// MARK: - BotStore (#417)
//
// The registry of bots (name + platform + token). Mirrors `ServerHostStore`: the
// non-secret fields go to UserDefaults as JSON; each bot's token lives in the iOS
// Keychain under the bot's UUID, so it isn't written to UserDefaults or backups.
// Deploying a bot to a server copies its token into that server's config;
// removing a bot from a server doesn't change this registry.

@MainActor
final class BotStore: ObservableObject {
    @Published var bots: [BotIdentity] = [] {
        didSet { save() }
    }

    private let storeKey = "olcrtc_bots"
    private static let keychainService = "olcrtc.bot.token"

    init() {
        // boc #470: "never stored" and "stored but unreadable" looked the same
        // here — `load()` swallowed the decode error and left `bots` empty — so
        // the first-run seed below wrote itself over a blob this build could not
        // read (a platform rawValue from a newer build, a corrupt byte) through
        // `didSet`, on launch, before the user touched anything; every deployed
        // bot's token was then orphaned in the Keychain under a UUID the app no
        // longer knew. An unreadable registry now stays on disk until the user's
        // own first change (a build that can read it gets it back) and renders
        // empty; only a genuinely absent one is seeded.
        let stored = load()
        // Seed a default Telegram bot on first run so the registry is never empty
        // and the per-server sheet always has something to pick.
        // #470 was: if bots.isEmpty {
        if bots.isEmpty, !stored {
            bots = [BotIdentity(name: BotIdentity.defaultName, platform: .telegram)]
        }
        // eoc #470
    }

    func add(_ bot: BotIdentity, token: String) {
        bots.append(bot)
        KeychainHelper.set(token, service: Self.keychainService, account: bot.id.uuidString)
    }

    /// Updates a bot's fields. A non-empty `token` replaces the stored one;
    /// `nil`/empty keeps the existing token (the editor leaves the field blank to
    /// mean "unchanged" — same convention as the SSH password in
    /// `AddServerHostView`).
    func update(_ bot: BotIdentity, token: String?) {
        if let i = bots.firstIndex(where: { $0.id == bot.id }) {
            bots[i] = bot
        }
        if let token, !token.isEmpty {
            KeychainHelper.set(token, service: Self.keychainService, account: bot.id.uuidString)
        }
    }

    func remove(_ bot: BotIdentity) {
        KeychainHelper.delete(service: Self.keychainService, account: bot.id.uuidString)
        bots.removeAll { $0.id == bot.id }
    }

    func remove(at idx: IndexSet) {
        let removed = idx.compactMap { bots.indices.contains($0) ? bots[$0] : nil }
        for b in removed {
            KeychainHelper.delete(service: Self.keychainService, account: b.id.uuidString)
        }
        bots.remove(atOffsets: idx)
    }

    func token(for bot: BotIdentity) -> String {
        KeychainHelper.get(service: Self.keychainService, account: bot.id.uuidString) ?? ""
    }

    /// Whether a token is stored for `bot` — for a UI hint.
    func hasToken(_ bot: BotIdentity) -> Bool {
        !token(for: bot).isEmpty
    }

    /// All configured bot names — the names `checkBots` probes on a server.
    var markers: [String] { bots.map(\.name) }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(bots) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
    // boc #470: returns whether a registry blob exists at all, readable or not,
    // and says so in the log when it is not — `init` seeds only when it does not.
    // #470 was: `if let data = …, let list = try? decode(…) { bots = list }` (Void).
    private func load() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return false }
        if let list = try? JSONDecoder().decode([BotIdentity].self, from: data) {
            bots = list
        } else {
            LogStore.shared.log(.connection,
                "⚠ Bot registry could not be read — showing an empty list; the stored copy is kept",
                level: .warn)
        }
        return true
    }
    // eoc #470
}
