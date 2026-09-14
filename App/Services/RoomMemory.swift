import Foundation

// MARK: - RoomMemory (#456)
//
// #456: remembers the last room ID the user actually used per carrier, so
// install / reconfigure / add-connection stop asking for what the app knows.
// The user's complaint was concrete: reinstalling a server re-asked for the
// telemost room the app already had in the linked record.
//
// Deliberately a plain `enum` of statics backed by UserDefaults — NOT an
// ObservableObject and NOT an init parameter. Several unrelated screens
// read/write it, and threading it through their initializers would make three
// sheets agree on one memberwise-init argument order for no benefit. Room IDs
// are not secrets (the key is; the room is a public conference identifier), so
// UserDefaults is the right place.
//
// Persistence: a brand-new key holding `[String: String]`. A decode failure
// yields an empty map and touches no other key — it can never harm
// `olcrtc_records_v2`.

enum RoomMemory {

    private static let storeKey = "olcrtc_last_rooms_v1"

    /// The last room the user used for `carrier`, or nil when nothing is known.
    static func lastRoom(forCarrier carrier: String) -> String? {
        let key = carrier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let value = load()[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Records the room the user actually used. Empty / whitespace-only carriers
    /// and rooms are ignored — remembering "" would suppress a real suggestion
    /// later without ever offering one.
    static func remember(carrier: String, room: String) {
        let c = carrier.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !r.isEmpty else { return }
        var map = load()
        map[c] = r
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private static func load() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }              // corrupt ⇒ start empty, never throw
        return decoded
    }
}
