import Foundation

// MARK: - TelemostRoom (#463)

/// A freshly created Yandex Telemost conference.
///
/// Both halves are kept because both are wanted downstream: the server config
/// takes the BARE id (`OlcrtcConnection.roomID` for telemost holds the id, not
/// a URL — see `roomIDTelemostHint` and upstream `internal/auth/telemost`, whose
/// provider accepts "the full URL … or just the room ID hash"), while the UI
/// shows / shares the full link the user would otherwise have copied by hand.
struct TelemostRoom: Equatable, Sendable {
    /// `https://telemost.yandex.ru/j/<id>` — exactly what the API returned.
    let uri: String
    /// `<id>` — the last path component after `/j/`.
    let id: String
}

// MARK: - TelemostRoomError (#463)

/// Everything that can go wrong creating a room, in the shape a view can ACT on:
/// sign in, wait, retry, or report. No case ever carries the session cookie, the
/// request headers or the response body — only a status code, which is safe.
enum TelemostRoomError: LocalizedError, Equatable {
    /// No Yandex account has been linked yet — nothing to authenticate with.
    case noSession
    /// HTTP 401: the stored `Session_id` is expired or revoked. The user must
    /// sign in again; there is nothing the app can retry.
    case sessionRejected
    /// HTTP 403 / 429 / 503: Yandex is refusing the request for now — too many
    /// meetings, an anti-robot check, or a temporary block. Waiting can fix it.
    case rateLimited
    /// The request never got an answer (offline, DNS poisoned, host blocked).
    case networkUnavailable
    /// A 2xx whose body is not the `{"uri": …}` we know how to read.
    case malformedResponse
    /// Any other HTTP status, carried so the log and the alert can name it.
    case serviceError(status: Int)

    var errorDescription: String? {
        switch self {
        case .noSession:            return L10n.telemostErrNoAccount.localized()
        case .sessionRejected:      return L10n.telemostErrSessionRejected.localized()
        case .rateLimited:          return L10n.telemostErrRateLimited.localized()
        case .networkUnavailable:   return L10n.telemostErrNetwork.localized()
        case .malformedResponse:    return L10n.telemostErrMalformed.localized()
        case .serviceError(let s):  return L10n.telemostErrStatus_fmt.formatted(s)
        }
    }

    /// Whether the only way out is for the user to (re-)link a Yandex account —
    /// the view uses this to jump straight to the sign-in sheet instead of
    /// offering a pointless "retry".
    var needsSignIn: Bool {
        self == .noSession || self == .sessionRejected
    }
}

// MARK: - TelemostRoomService (#463)
//
// One button's worth of API: create a fresh Telemost conference from the phone.
//
// Why the phone and not the VPS
// -----------------------------
// A Telemost link "works for 24 hours" and a server sitting in the room does not
// extend it. If the VPS rotated its own room, the phone could never learn the
// new id — during a whitelist window the only channel to the phone is the
// tunnel, which just died with the old room. So the phone mints the room and
// pushes the id down the (still usable) SSH path; see SSHTransport (#462).
//
// The request
// -----------
// Creating a room is ONE authenticated POST to the FREE "front" API the Telemost
// web client itself calls — not the paid business API at
// `cloud-api.yandex.net/v1/telemost-api/`, which 403s without a Yandex 360 for
// Business subscription. The whole credential is the `Session_id` cookie of an
// ordinary personal account; there is no CSRF token and nothing is signed.
// Joining stays anonymous (our own core joins with no cookie —
// `olcrtc-upstream/internal/auth/telemost/api.go`), so nothing about the tunnel
// changes.
//
// The header set below is NOT invented: it is the one our own Go core already
// sends to this same host and base URL (`connectionInfo` in that file), plus the
// `Cookie` the create call additionally needs. Keeping the two identical means a
// future header change is found in one obvious place.
//
// Isolation: a nonisolated `enum` of statics, like every other stateless service
// here (SubscriptionFetcher, NetPing, PortAvailability). Log lines hop to
// MainActor one at a time.

enum TelemostRoomService {

    // MARK: Endpoint

    /// Base of the front API — identical to `defaultAPIURL` in upstream
    /// `internal/auth/telemost/api.go`.
    static let apiBase = "https://cloud-api.yandex.ru/telemost_front/v2/telemost"

    /// The create-conference endpoint. Force-unwrapped like the other constant
    /// URLs in this codebase (`AppConstants.Update.latestReleaseAPIURL`): it is a
    /// literal with no interpolation, so it cannot fail at runtime.
    static let createURL = URL(string:
        "\(apiBase)/conferences?next_gen_media_platform_allowed=true")!

    /// Marker the room id follows in a Telemost link — upstream's
    /// `roomURLPrefix` is `https://telemost.yandex.ru/j/`.
    private static let roomPathMarker = "/j/"

    // Header values, verbatim from upstream `telemost/api.go` so the app and the
    // Go core present the same client to Yandex.
    private static let userAgent =
        "Mozilla/5.0 (X11; Linux x86_64; rv:149.0) Gecko/20100101 Firefox/149.0"
    private static let clientVersion = "187.1.0"
    private static let origin  = "https://telemost.yandex.ru"
    private static let referer = "https://telemost.yandex.ru/"

    /// Direct is a plain HTTPS round trip; the tunnel leg is a vp8/datachannel
    /// carrier and needs a longer rope for the same exchange.
    private static let directTimeout: TimeInterval = 20
    private static let tunnelTimeout: TimeInterval = 40

    // MARK: Create

    /// Creates a new Telemost conference and returns its link and bare id.
    ///
    /// Route: whatever the app is ALREADY using for VPS administration. There is
    /// no second routing policy in this file — `SSHTransport.currentRoute()` is
    /// the single source of truth for "is the in-app SOCKS proxy really there",
    /// and `SSHTransport.nextRoute` is its (unit-tested) one-shot fallback rule.
    /// Both directions matter here:
    ///   * tunnel first when one is live — during a whitelist window a direct
    ///     HTTPS call to cloud-api.yandex.ru can be cut, while the tunnel (whose
    ///     carrier is on the whitelist) still carries it, and the exit container
    ///     runs `--network host` with no address blocklist;
    ///   * direct when no tunnel is live — which is the COMMON case for this
    ///     feature, because the room usually expired and took the tunnel with it.
    /// A transport failure retries once on the other path; an answer that
    /// actually arrived (401 / 429 / bad body) is never re-sent, because the
    /// other route would produce the same answer.
    /// #470: with one exception — a refusal (403/429/503) received THROUGH the
    /// tunnel is answered to the exit's datacenter address, and Yandex's
    /// anti-robot gate keys on that address; the phone's own gets one try.
    static func createRoom() async throws -> TelemostRoom {
        guard let sessionID = YandexSessionStore.storedSession() else {
            await log("Telemost: cannot create a room — no Yandex account is linked")
            throw TelemostRoomError.noSession
        }

        let available = await SSHTransport.currentRoute()
        do {
            return try await createRoom(sessionID: sessionID, route: available)
        } catch TelemostRoomError.networkUnavailable {
            let fallback = SSHTransport.nextRoute(attempt: 2,
                                                  previous: available,
                                                  available: available)
            guard fallback != available else { throw TelemostRoomError.networkUnavailable }
            await log("Telemost: retrying room creation (route: \(fallback))")
            return try await createRoom(sessionID: sessionID, route: fallback)
        } catch TelemostRoomError.rateLimited where available.isTunnel {
            // boc #470: every retry while the tunnel was live took the same
            // route and got the same per-IP 403, so the sheet dead-ended on
            // "wait and retry" for a room a direct POST would have created. A
            // direct path that is itself cut (whitelist window) reports the
            // ORIGINAL refusal, not "no network".
            await log("Telemost: the refusal may be about the exit's address — retrying directly")
            do {
                return try await createRoom(sessionID: sessionID, route: .direct)
            } catch TelemostRoomError.networkUnavailable {
                throw TelemostRoomError.rateLimited
            }
            // eoc #470
        }
    }

    /// One POST on one route.
    ///
    /// `sessionID` is the raw `Session_id` cookie value. It is written into the
    /// `Cookie` header and NOWHERE else — not into a log line, not into a thrown
    /// error, not into the session's cookie storage (`httpShouldHandleCookies`
    /// is off, so URLSession neither substitutes our header from its jar nor
    /// persists the response's `Set-Cookie`).
    private static func createRoom(sessionID: String,
                                   route: SSHTransport.Route) async throws -> TelemostRoom {
        let timeout = route.isTunnel ? tunnelTimeout : directTimeout

        var req = URLRequest(url: createURL, timeoutInterval: timeout)
        req.httpMethod   = "POST"
        req.httpBody     = Data("{}".utf8)
        req.cachePolicy  = .reloadIgnoringLocalAndRemoteCacheData
        req.httpShouldHandleCookies = false
        req.setValue("\(YandexSessionStore.cookieName)=\(sessionID)", forHTTPHeaderField: "Cookie")
        req.setValue(userAgent,          forHTTPHeaderField: "User-Agent")
        req.setValue("*/*",              forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(origin,             forHTTPHeaderField: "Origin")
        req.setValue(referer,            forHTTPHeaderField: "Referer")
        req.setValue(clientVersion,      forHTTPHeaderField: "X-Telemost-Client-Version")
        // Fresh per call, exactly like the web client (and upstream's
        // `connectionInfo`): a stable Idempotency-Key would make a second tap
        // hand back the SAME conference instead of a new one.
        req.setValue(UUID().uuidString,  forHTTPHeaderField: "Client-Instance-Id")
        req.setValue(UUID().uuidString,  forHTTPHeaderField: "Idempotency-Key")

        // The app's normal networking: `.tunnel` gets the live SOCKS port AND
        // its credentials from TunnelManager, `.direct` is a plain ephemeral
        // session. No third way to reach the network exists in this app.
        let urlSession = SOCKSSession.make(mode: route.isTunnel ? .tunnel : .direct,
                                           timeout: timeout)
        defer { urlSession.finishTasksAndInvalidate() }

        await log("Telemost: requesting a new room (route: \(route))")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch let error as URLError {
            // The URLError code is a system diagnostic, never anything of ours.
            await log("Telemost: no answer from the API (route: \(route), URLError \(error.code.rawValue))")
            throw TelemostRoomError.networkUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            await log("Telemost: the API answered with a non-HTTP response")
            throw TelemostRoomError.malformedResponse
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            // The documented no-/stale-cookie answer:
            // {"error":"UnauthorizedError","message":"…"} — the body is never
            // surfaced, the status is enough to know what to tell the user.
            await log("Telemost: the saved Yandex session was rejected (401)")
            throw TelemostRoomError.sessionRejected
        case 403, 429, 503:
            await log("Telemost: the API refused the request (\(http.statusCode))")
            throw TelemostRoomError.rateLimited
        default:
            await log("Telemost: the API returned HTTP \(http.statusCode)")
            throw TelemostRoomError.serviceError(status: http.statusCode)
        }

        // A successful transfer through the tunnel counts as tunnel activity, so
        // keep-alive skips its next probe (same contract as IPChecker/SpeedTest).
        if route.isTunnel { SOCKSSession.noteTunnelActivity() }

        let room = try await decodeOrLog(data)
        await log("Telemost: new room created — \(room.id)")
        return room
    }

    // MARK: Pure parsing

    /// PURE. Decodes the create-conference response.
    ///
    /// The API answers `{"uri":"https://telemost.yandex.ru/j/<id>"}`. Anything
    /// else — a different shape, a missing/empty `uri`, a link with no `/j/`
    /// segment, plain HTML from an interception page — is `.malformedResponse`.
    static func decodeRoom(_ data: Data) throws -> TelemostRoom {
        guard let payload = try? JSONDecoder().decode(ConferenceResponse.self, from: data),
              let raw = payload.uri?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let id = roomID(fromURI: raw)
        else { throw TelemostRoomError.malformedResponse }
        return TelemostRoom(uri: raw, id: id)
    }

    /// PURE. The bare room id out of a Telemost link — the last path component
    /// after `/j/`, which is what the server config wants.
    ///
    ///   `https://telemost.yandex.ru/j/1234567890`   -> `1234567890`
    ///   `https://telemost.yandex.ru/j/1234567890/`  -> `1234567890`
    ///   `https://telemost.yandex.ru/j/123?utm=x`    -> `123`
    ///   anything without `/j/`, or with an empty id -> nil
    ///
    /// The id is also charset-checked (`A-Z a-z 0-9 - _`). That is deliberate:
    /// this value is about to be written into the server's `server.yaml` through
    /// an SSH command line, so refusing an id we do not recognise is safer than
    /// leaning on `SSHRunner.shellSafe` to strip it afterwards.
    static func roomID(fromURI uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = trimmed.range(of: roomPathMarker,
                                         options: [.backwards, .caseInsensitive])
        else { return nil }

        var tail = String(trimmed[marker.upperBound...])
        if let cut = tail.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            tail = String(tail[..<cut])
        }
        guard let last = tail.split(separator: "/").last else { return nil }
        let component = String(last)
        guard !component.isEmpty,
              component.allSatisfy({ isRoomIDCharacter($0) })
        else { return nil }
        return component
    }

    /// `A-Z a-z 0-9 - _`, written with the same `isASCII && (isLetter || isNumber)`
    /// idiom as `ServerHost.sanitizeLogFilePrefix` so non-ASCII look-alikes
    /// (Cyrillic "о", full-width digits) are rejected rather than folded.
    private static func isRoomIDCharacter(_ ch: Character) -> Bool {
        guard ch.isASCII else { return false }
        return ch.isLetter || ch.isNumber || ch == "-" || ch == "_"
    }

    /// The `{"uri": …}` envelope. Optional so a foreign body decodes cleanly to
    /// nil and becomes `.malformedResponse` rather than a decoding throw.
    struct ConferenceResponse: Decodable {
        let uri: String?
    }

    // MARK: Logging

    private static func decodeOrLog(_ data: Data) async throws -> TelemostRoom {
        do {
            return try decodeRoom(data)
        } catch {
            // Byte count only — the body could carry account-scoped fields.
            await log("Telemost: the API answered with an unreadable body (\(data.count) bytes)")
            throw TelemostRoomError.malformedResponse
        }
    }

    /// Every line here is engineering English and MUST stay free of the session
    /// cookie; `LogStore.log` also runs `redactSecrets` as a second net.
    private static func log(_ line: String) async {
        await MainActor.run { LogStore.shared.log(.provisioning, line) }
    }
}
