import Foundation
@preconcurrency import Citadel
import NIO

// MARK: - Provisioning
//
// Manages remote operations against a ServerHost via SSH:
//   - install   — uploads scripts/srv.sh to the VPS, runs it with env vars
//                 set from InstallOptions, parses OLCRTC_URI= and
//                 OLCRTC_CONTAINER= from the output, returns InstallResult.
//   - uninstall — stops + removes any olcrtc-server-* containers and cleans up.
//   - reboot    — issues `sudo reboot`.
//   - ping      — TCP-22 reachability check.
//
// scripts/srv.sh is a full copy of upstream olcrtc-upstream/script/srv.sh with our
// modifications marked using # boc olcrtc-ios / # eoc olcrtc-ios markers.
// parity_check.py (run as a build phase) verifies that unmarked lines stay
// identical to upstream — if upstream changes a flag or command we rely on,
// the build fails until we deliberately update scripts/srv.sh.
//
// All interactive prompts in srv.sh are replaced in our boc/eoc patches
// with env var reads (OLCRTC_CARRIER, OLCRTC_TRANSPORT, OLCRTC_ROOM_ID,
// etc.) so the script can run non-interactively over SSH.

/// Errors thrown by SSHRunner and surfaced to the UI via Provisioner.status.
/// `.sshConnect` / `.sshCommand` wrap Citadel errors; `.parseFailed` covers
/// missing output keys or install timeouts.
enum ProvisionError: LocalizedError {
    case missingPassword
    case sshConnect(String)
    case sshCommand(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPassword:      return L10n.provisionPasswordMissing.localized()
        case .sshConnect(let m):    return L10n.provisionSSHPrefix_fmt.formatted(m)
        case .sshCommand(let m):    return L10n.provisionCommandPrefix_fmt.formatted(m)
        case .parseFailed(let m):   return L10n.provisionParsePrefix_fmt.formatted(m)
        }
    }
}

struct InstallResult: Sendable {
    let uri: String              // olcrtc://...
    let containerName: String    // for later uninstall
}

/// User-chosen install parameters. Everything else (client-id, key, dns) is
/// filled in with defaults inside the install script.
///
/// Carrier matrix (mirrors upstream `script/srv.sh`):
///   - telemost, wbstream, jitsi → room ID must be supplied (created by the
///                                  user on telemost.yandex.ru / stream.wb.ru,
///                                  or a Jitsi room name/URL)
///
/// Transport defaults per carrier — wbstream disabled datachannel on their
/// side so we fall back to vp8channel for that one. Users can override in
/// the install sheet if a carrier changes what works.
struct InstallOptions: Sendable, Equatable {
    var carrier:   String       // "telemost" | "wbstream" | "jitsi"
    var transport: String       // "datachannel" | "vp8channel" | "seichannel" | "videochannel"
    var roomID:    String       // required; the server needs an explicit room ID

    /// Jitsi rendezvous base URL, sent as `OLCRTC_JITSI_URL` only when
    /// `carrier == "jitsi"` (#256). Pre-filled from `AppConstants.defaultJitsiBaseURL`
    /// but user-overridable in the install sheet, so users can point at their own
    /// instance instead of the shared public default. Never empty (the sheet falls
    /// back to the default if cleared).
    var jitsiBaseURL: String = AppConstants.defaultJitsiBaseURL

    // SEI channel tunables — only consumed by installEnv() when transport == "seichannel".
    var seiFPS  : Int = 30
    var seiBatch: Int = 10
    var seiFrag : Int = 1200
    var seiACK  : Int = 1

    /// #436: wbstream account token → server config `auth.token` (via
    /// `OLCRTC_WB_TOKEN`). Only emitted when `carrier == "wbstream"` and non-empty;
    /// a secret, so it's never logged (installEnv redacts it in the command preview).
    var wbToken : String = ""

    static let `default` = InstallOptions(carrier: "wbstream",
                                          transport: "datachannel",
                                          roomID: "")

    var requiresRoomID: Bool { CarrierTransportMatrix.requiresRoomID(carrier: carrier) }

    static func defaultTransport(for carrier: String) -> String {
        CarrierTransportMatrix.defaultTransport(for: carrier)
    }
}

enum ProvisionStatus: Equatable {
    case idle
    case running(String)
    case success(String)
    case failure(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Live state of the olcrtc container on a VPS, parsed from `podman ps`.
///
/// `podman ps -a --filter "name=^<cname>$" --format "{{.Status}}"` prints
/// one line like "Up 2 hours" for running containers, "Exited (137) 5
/// minutes ago" for stopped, and nothing at all when the container doesn't
/// exist. We compress those into the three cases below.
/// Richer VPS readiness state — what's actually installed on the server.
/// Probed via `Provisioner.probeReadiness(on:secret:)` which runs a single
/// SSH call checking Podman, golang image, and the named container.
enum VPSReadinessState: Equatable, Sendable {
    case noPodman                    // Podman not installed → first install takes full ~5-7 min
    case noImage                     // Podman present, image not cached → ~3-5 min
    case imageReady                  // Image cached, no container → reinstall ~1-2 min
    case containerStopped(String)    // Container exists but not running
    case containerRunning(String)    // Container up and running

    var label: String {
        switch self {
        case .noPodman:                return L10n.readinessNoPodman.localized()
        case .noImage:                 return L10n.readinessNoImage.localized()
        case .imageReady:              return L10n.readinessImageReady.localized()
        case .containerStopped(let s): return L10n.readinessContainerStopped_fmt.formatted(s)
        case .containerRunning(let s): return L10n.readinessContainerRunning_fmt.formatted(s)
        }
    }

    var dot: String {
        switch self {
        case .containerRunning: return "🟢"
        case .containerStopped: return "🔴"
        case .imageReady:       return "🟡"
        default:                return "⚪"
        }
    }
}

enum ContainerStatus: Equatable, Sendable {
    case running(String)   // "Up 2 hours"
    case stopped(String)   // "Exited (137) 5 minutes ago"
    case notFound

    /// Short label shown next to the indicator dot on the host card.
    var shortLabel: String {
        switch self {
        case .running(let s): return s
        case .stopped(let s): return s
        case .notFound:       return L10n.containerNotFoundShort.localized()
        }
    }

    /// Parses raw `podman ps --format "{{.Status}}"` output.
    /// Empty string → notFound; "Up …" → running; anything else → stopped.
    static func parse(from raw: String) -> ContainerStatus {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty         { return .notFound }
        if s.hasPrefix("Up") { return .running(s) }
        return .stopped(s)
    }
}

/// Coordinates SSH-based VPS operations and publishes a single `status`
/// so the UI can show a progress banner. Delegates all SSH work to the
/// nonisolated `SSHRunner` enum; only one operation runs at a time.
@MainActor
final class Provisioner: ObservableObject {
    @Published var status: ProvisionStatus = .idle

    // boc #470: ServersView serialises its OWN ops (`anyBusy`), but the Telemost
    // renewal coordinator holds a SECOND Provisioner and runs unattended — so a
    // renewal could restart a container while an install or a key rotation was
    // half-way through it, on the same host, through a different SSH session.
    // One process-wide registry of hosts under an SSH op; the unattended side
    // yields to the user's.
    @MainActor private static var busyHosts: Set<UUID> = []
    @MainActor static var busyHostIDs: Set<UUID> { busyHosts }
    // boc #482: atomically claim before any await; both manual ops and renewal
    // must own the same lane. Only a successful claimant may call leaveHost.
    // #482 was: static func enterHost(_ id: UUID) { busyHosts.insert(id) }
    @MainActor static func tryEnterHost(_ id: UUID) -> Bool {
        busyHosts.insert(id).inserted
    }
    // eoc #482
    @MainActor static func leaveHost(_ id: UUID) { busyHosts.remove(id) }
    // eoc #470

    // MARK: Ping

    /// TCP-22 reachability check. Doesn't need creds, so we route directly
    /// to NetPing without going through Citadel.
    func ping(host: ServerHost) async {
        status = .running("Ping \(host.host):\(host.port)…")
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Ping \(host.host):\(host.port)")
        let result = await NetPing.tcp(host: host.host, port: UInt16(clamping: host.port))   // #469: never trap on a stored value
        if result.success, let ms = result.ms {
            let msg = L10n.pingTCPOK_fmt.formatted(host.port, String(format: "%.0f", ms))
            LogStore.shared.log(.provisioning, "✓ \(msg)")
            status = .success(msg)
        } else {
            let msg = L10n.pingTCPFail_fmt.formatted(host.port)
            LogStore.shared.log(.provisioning, "✗ \(msg)")
            status = .failure(msg)
        }
    }

    // MARK: Reachability pre-probe
    //
    // Quick TCP-22 ping before each SSH-driven action. Citadel itself has a
    // 30 s connect timeout × 2 retries = up to 64 s before failure surfaces.
    // For a completely unreachable VPS (power off, ISP block, wrong IP) that's
    // a painful wait. A 5 s probe finds the bad cases up-front and surfaces
    // a friendly "Server is not responding" message instead.

    // #469 was: 5 — shorter than the 15 s the dial itself gives the tunnel relay
    // (SSHTransport) and the core's 15 s CONNECT-ack wait, so a working tunnel
    // route was vetoed by its own pre-check whenever the carrier took more than
    // five seconds to answer (vp8channel / seichannel, a mid-renegotiation
    // room). A dead VPS now costs 15 s to report instead of 5; a live tunnel
    // is no longer refused for being slow.
    private static let probeTimeout: TimeInterval = 15

    /// Throws `ProvisionError.sshConnect(serverUnreachable_fmt)` if TCP-port
    /// is not reachable within `probeTimeout` seconds. On success returns
    /// quickly (~50–200 ms) and the caller proceeds with SSH.
    // boc #462 (audit): this pre-probe gates EVERY SSH-driven op, so while it
    // pinged the public IP directly it vetoed the tunnel route before
    // `SSHRunner.connect` ever got to choose one — during the carrier whitelist
    // window that #462 exists for, the direct TCP-22 probe fails and the whole
    // operation aborted with "server is not responding" even though the tunnel
    // could carry the session end to end. `SSHRunner.reachabilityProbe` measures
    // the path the SSH dial will actually take and still falls back to the
    // direct probe when the tunnel path fails, so a genuinely dead VPS is still
    // caught in ~5 s.
    // #462 was: `let result = await NetPing.tcp(host: host.host, port: UInt16(host.port), timeout: Self.probeTimeout)`
    private func ensureReachable(_ host: ServerHost) async throws {
        let result = await SSHRunner.reachabilityProbe(host: host.host,
                                                       port: host.port,
                                                       timeout: Self.probeTimeout)
        guard result.success else {
            let target = "\(host.host):\(host.port)"
            let msg = L10n.serverUnreachable_fmt.formatted(target)
            LogStore.shared.log(.provisioning, "✗ \(msg)")
            throw ProvisionError.sshConnect(msg)
        }
        if let ms = result.ms {
            let path = result.viaTunnel ? L10n.routingViaTunnel.localized()
                                        : L10n.routingDirect.localized()
            LogStore.shared.log(.provisioning,
                "✓ TCP/\(host.port) reachable (\(String(format: "%.0f", ms)) ms, \(path))")
        }
    }
    // eoc #462

    // MARK: Install / Uninstall / Reboot

    // #451: every SSH-driven method now takes the host's SSHSecret (password
    // OR private key) instead of a bare password string. `scanContainers` and
    // `containerLogs` additionally keep `password:`-labelled String overloads
    // for the pre-#451 call sites (LogsView) — see those below.

    func install(on host: ServerHost, secret: SSHSecret,
                 options: InstallOptions) async throws -> InstallResult {
        status = .running(L10n.provisioningSSHConnecting.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning,
            "→ Install: SSH \(host.username)@\(host.host):\(host.port) carrier=\(options.carrier) transport=\(options.transport)" +
            (options.requiresRoomID ? " room=\(options.roomID.prefix(8))…" : " room=auto"))
        do {
            try await ensureReachable(host)
            let result = try await SSHRunner.install(host: host, secret: secret,
                                                      options: options,
                                                      onStep: stepHandler())
            status = .success(L10n.installResultSuccess_fmt.formatted(options.carrier, options.transport))
            return result
        } catch {
            LogStore.shared.log(.provisioning, "✗ Install failed: \(error.localizedDescription)")
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func uninstall(on host: ServerHost, secret: SSHSecret, containerName: String?) async throws {
        status = .running(L10n.provisioningUninstallSSH.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Uninstall on \(host.host)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.uninstall(host: host, secret: secret,
                                           containerName: containerName,
                                           onStep: stepHandler())
            status = .success(L10n.uninstallResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    /// #451: returns the container name the update script resolved (recorded
    /// name, or the first olcrtc-server-* found when none was recorded) so
    /// the caller can adopt it into `host.lastContainerName`.
    @discardableResult
    func update(on host: ServerHost, secret: SSHSecret, containerName: String?) async throws -> String? {
        status = .running(L10n.provisioningUpdating.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Update on \(host.host)")
        do {
            try await ensureReachable(host)
            let resolved = try await SSHRunner.update(host: host, secret: secret,
                                                      containerName: containerName,
                                                      onStep: stepHandler())
            status = .success(L10n.updateResultSuccess.localized())
            return resolved
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func start(on host: ServerHost, secret: SSHSecret, containerName: String) async throws {
        status = .running(L10n.provisioningStarting.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Start on \(host.host): \(containerName)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.start(host: host, secret: secret,
                                      containerName: containerName,
                                      onStep: stepHandler())
            status = .success(L10n.startResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func stop(on host: ServerHost, secret: SSHSecret, containerName: String) async throws {
        status = .running(L10n.provisioningStopping.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Stop on \(host.host): \(containerName)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.stop(host: host, secret: secret,
                                     containerName: containerName,
                                     onStep: stepHandler())
            status = .success(L10n.stopResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func deepUninstall(on host: ServerHost, secret: SSHSecret,
                       containerName: String?, removeImage: Bool) async throws {
        status = .running(L10n.provisioningUninstalling.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Deep uninstall on \(host.host) removeImage=\(removeImage)")
        do {
            try await ensureReachable(host)
            try await SSHRunner._withConnection(host: host, secret: secret) { client in
                _ = try await SSHRunner._execute(
                    client: client, label: "deep-uninstall",
                    command: SSHRunner.deepUninstallScript(containerName: containerName,
                                                          removeImage: removeImage))
            }
            status = .success(L10n.deepUninstallResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // MARK: Scan for existing containers

    /// #451-compat: String-credential overload kept so the pre-SSHSecret call
    /// site (LogsView.primaryAction) compiles unchanged AND still works for
    /// key hosts: `password` there is whatever `ServerHostStore.password(for:)`
    /// returned (the password, or the key text for key hosts), and
    /// `resolveSecret` rebuilds the full secret from it + the Keychain.
    func scanContainers(on host: ServerHost, password: String) async throws -> [SSHRunner.FoundContainer] {
        try await scanContainers(on: host,
                                 secret: ServerHostStore.resolveSecret(for: host, credential: password))
    }

    func scanContainers(on host: ServerHost, secret: SSHSecret) async throws -> [SSHRunner.FoundContainer] {
        status = .running(L10n.scanningContainers.localized())
        LogStore.shared.log(.provisioning, "→ Scanning \(host.host) for olcrtc containers…")
        do {
            try await ensureReachable(host)
            let output = try await SSHRunner._withConnection(host: host, secret: secret) { client in
                try await SSHRunner._execute(client: client, label: "scan",
                                             command: SSHRunner.scanContainersScript())
            }
            let found = SSHRunner.parseScannedContainers(from: output)
            LogStore.shared.log(.provisioning, "✓ Found \(found.count) olcrtc container(s)")
            status = .idle
            return found
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // MARK: VPS readiness probe

    /// Single SSH call that checks Podman, the golang image, and the container.
    /// Cheap (~1 s RTT), safe to call on every Status refresh.
    /// Does NOT touch `status` — callers that want spinner/button-lock use
    /// `checkReadiness` instead.
    func probeReadiness(on host: ServerHost, secret: SSHSecret,
                        containerName: String?) async throws -> (VPSReadinessState, SSHRunner.VPSStats?) {
        LogStore.shared.startSession(.provisioning)
        try await ensureReachable(host)
        let output = try await SSHRunner._withConnection(host: host, secret: secret) { client in
            try await SSHRunner._execute(client: client, label: "readiness",
                                         command: SSHRunner.readinessScript(containerName: containerName))
        }
        let state = try SSHRunner.parseReadiness(from: output, containerName: containerName)
        let stats = SSHRunner.parseVPSStats(from: output)
        return (state, stats)
    }

    /// Same as `probeReadiness` but sets `status` so the card shows a yellow
    /// in-progress indicator and buttons are disabled. Use for explicit user-
    /// initiated checks; internal post-operation probes call `probeReadiness`
    /// directly to avoid overwriting the operation's own status.
    func checkReadiness(on host: ServerHost, secret: SSHSecret,
                        containerName: String?) async throws -> (VPSReadinessState, SSHRunner.VPSStats?) {
        status = .running(L10n.provisioningStatusFetching.localized())
        do {
            let result = try await probeReadiness(on: host, secret: secret, containerName: containerName)
            status = .idle
            return result
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // MARK: Container status + logs

    /// Probes `podman ps` over SSH and reports whether the named container
    /// is running. Cheap (one short command), so it's safe to bind to a
    /// "refresh" button on the host card.
    func containerStatus(on host: ServerHost, secret: SSHSecret,
                          containerName: String) async throws -> ContainerStatus {
        status = .running(L10n.provisioningStatusFetching.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning,
            "→ Status: \(containerName) on \(host.host)")
        do {
            try await ensureReachable(host)
            let result = try await SSHRunner.containerStatus(
                host: host, secret: secret,
                containerName: containerName,
                onStep: stepHandler())
            let msg: String
            switch result {
            case .running(let s): msg = L10n.containerRunning_fmt.formatted(s)
            case .stopped(let s): msg = L10n.containerStopped_fmt.formatted(s)
            case .notFound:       msg = L10n.containerNotFound.localized()
            }
            LogStore.shared.log(.provisioning, "✓ \(msg)")
            status = .success(msg)
            return result
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    /// Pulls `podman logs --tail N` over SSH. Returns the raw text and ALSO
    /// dumps each line into this server's per-host `.containerLogs` buffer/file
    /// (#295: `<host.logFilePrefix>_container.log`) so the user can scroll
    /// through it in the Logs tab's Container category. #339 was: "Returned
    /// string is what the calling view shows in its sheet" — the sheet is
    /// gone; callers read the buffer, the return value is unused today.
    /// #451-compat: String-credential overload for LogsView (see scanContainers).
    func containerLogs(on host: ServerHost, password: String,
                        containerName: String, tail: Int = 200) async throws -> String {
        try await containerLogs(on: host,
                                secret: ServerHostStore.resolveSecret(for: host, credential: password),
                                containerName: containerName, tail: tail)
    }

    func containerLogs(on host: ServerHost, secret: SSHSecret,
                        containerName: String, tail: Int = 200) async throws -> String {
        status = .running(L10n.provisioningLogsFetching.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning,
            "→ Logs: \(containerName) on \(host.host) (tail=\(tail))")
        do {
            try await ensureReachable(host)
            let output = try await SSHRunner.containerLogs(
                host: host, secret: secret,
                containerName: containerName, tail: tail,
                onStep: stepHandler())

            // #338: third real progress signal for the Logs tab's phase bar —
            // the SSH output is downloaded, now being parsed into the buffer.
            status = .running(L10n.logsPhaseReceiving.localized())

            // Persist into this server's own container-log file so it
            // survives the sheet being dismissed. #278: parse each line's Go
            // timestamp ("2006/01/02 15:04:05") into a real Date so the
            // container lines interleave chronologically with the client
            // stream instead of all clustering at fetch-time; lines without
            // their own stamp carry the previous line's date forward
            // (multi-line panics etc.). #295: per-server file/buffer, keyed
            // by the sanitised server-name prefix.
            // #476 was: `host.logFilePrefix` — the host alone, so every protocol
            // on it appended to one buffer and the Logs picker could not switch.
            let prefix = LogStore.containerKey(prefix: host.logFilePrefix, container: containerName)
            // #338: session divider with the command + time before the fetched
            // block (replaces the generic "── new session ──", design_handoff §2).
            LogStore.shared.startContainerSession(serverPrefix: prefix,
                // #476: the block says which container it came from — the buffers
                // are separate now, but an exported file is read out of context.
                divider: "── podman logs --tail \(tail) \(containerName) · \(Self.fetchStamp.string(from: Date())) ──")
            var carry = Date()
            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                let raw = String(line)
                if let parsed = LogStore.parseExternalTimestamp(raw) {
                    carry = parsed.date
                    LogStore.shared.logContainer(serverPrefix: prefix, parsed.rest, date: parsed.date)
                } else {
                    LogStore.shared.logContainer(serverPrefix: prefix, raw, date: carry)
                }
            }
            // Remember this host/container so the Logs tab can re-pull directly.
            LogStore.shared.noteContainerTarget(hostID: host.id, containerName: containerName, serverPrefix: prefix)

            status = .success(L10n.logsBytesReceived_fmt.formatted(output.count))
            return output
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func reconfigure(on host: ServerHost, secret: SSHSecret,
                     containerName: String, options: InstallOptions) async throws -> String? {
        status = .running(L10n.provisioningReconfiguring.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning,
            "→ Reconfigure on \(host.host): carrier=\(options.carrier) transport=\(options.transport)" +
            (options.requiresRoomID ? " room=\(options.roomID.prefix(8))…" : " room=auto"))
        do {
            try await ensureReachable(host)
            let env = SSHRunner.installEnv(options)
                .components(separatedBy: " ")
                .filter { !$0.isEmpty }
            let newURI = try await SSHRunner.reconfigure(host: host, secret: secret,
                                                         containerName: containerName, env: env,
                                                         onStep: stepHandler())
            if let uri = newURI {
                LogStore.shared.log(.provisioning, "✓ New URI: \(LogStore.redactSecrets(uri))")
            } else {
                LogStore.shared.log(.provisioning, "⚠ Reconfigure succeeded but server did not emit URI — ConnectionRecord not updated. Run Status to refresh.")
            }
            status = .success(L10n.reconfigureResultSuccess_fmt.formatted(options.carrier, options.transport))
            return newURI
        } catch {
            LogStore.shared.log(.provisioning, "✗ Reconfigure failed: \(error.localizedDescription)")
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // #303: read-only recovery of an existing server's connection params
    // (carrier/transport/room/key) from its deployed server.yaml, for hosts
    // where a container was found (#302 auto-detect) but no ConnectionRecord
    // is linked — e.g. fresh install / reinstall with an empty Connections tab.
    func recoverConfig(on host: ServerHost, secret: SSHSecret,
                       containerName: String,
                       configFile: String = "server.yaml") async throws -> SSHRunner.RecoveredConfig {
        status = .running(L10n.provisioningRecovering.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Recover config: \(containerName) (\(configFile)) on \(host.host)")
        do {
            try await ensureReachable(host)
            let cfg = try await SSHRunner.recoverConfig(host: host, secret: secret,
                                                        containerName: containerName,
                                                        configFile: configFile,   // #452
                                                        onStep: stepHandler())
            LogStore.shared.log(.provisioning,
                "✓ Recovered config: carrier=\(cfg.carrier) transport=\(cfg.transport) room=\(cfg.roomID.prefix(8))…")
            status = .success(L10n.recoverResultSuccess_fmt.formatted(cfg.carrier, cfg.transport))
            return cfg
        } catch {
            LogStore.shared.log(.provisioning, "✗ Recover config failed: \(error.localizedDescription)")
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // #314: "generate new key" fallback for #303 — when recoverConfig cannot
    // read/parse the deployed server.yaml, this rotates `~/.olcrtc_key` via
    // scripts/rotate-key.sh (srv.sh-parity script: same key-gen and YAML-write
    // lines), restarts the container, and returns the resulting URI/container
    // so the caller can add the connection like a fresh install.
    // #452: returns RotateKeyResult — the primary's URI/container (same
    // `uri`/`containerName` fields as before) plus the sibling carriers the
    // script also re-keyed, so the caller can update every affected record.
    func rotateKey(on host: ServerHost, secret: SSHSecret,
                   containerName: String) async throws -> SSHRunner.RotateKeyResult {
        status = .running(L10n.provisioningRotatingKey.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Rotate key: \(containerName) on \(host.host)")
        do {
            try await ensureReachable(host)
            let result = try await SSHRunner.rotateKey(host: host, secret: secret,
                                                       containerName: containerName,
                                                       onStep: stepHandler())
            LogStore.shared.log(.provisioning,
                "✓ Key rotated — new URI: \(LogStore.redactSecrets(result.uri))")
            // #452: siblings share the host key — every server-<carrier>.yaml
            // was rewritten and restarted too; surface how many followed.
            if !result.siblings.isEmpty {
                LogStore.shared.log(.provisioning,
                    "✓ Rotated \(result.siblings.count) sibling carrier(s) too")
            }
            status = .success(L10n.rotateKeyResultSuccess.localized())
            return result
        } catch {
            LogStore.shared.log(.provisioning, "✗ Rotate key failed: \(error.localizedDescription)")
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // MARK: #452 — Multi-carrier (sibling protocol containers)

    /// Adds a sibling carrier container to an already-installed host via
    /// scripts/add-carrier.sh — it reuses the deploy dir / binary / key of
    /// `baseContainer`, so the op takes seconds (no build). Returns the
    /// sibling's URI + container name in the same shape as a fresh install.
    func addCarrier(on host: ServerHost, secret: SSHSecret,
                    baseContainer: String, options: InstallOptions) async throws -> InstallResult {
        status = .running(L10n.provisioningSSHConnecting.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning,
            "→ Add carrier on \(host.host): base=\(baseContainer) carrier=\(options.carrier) transport=\(options.transport)" +
            (options.requiresRoomID ? " room=\(options.roomID.prefix(8))…" : " room=auto"))
        do {
            try await ensureReachable(host)
            let result = try await SSHRunner.addCarrier(host: host, secret: secret,
                                                        baseContainer: baseContainer,
                                                        options: options,
                                                        onStep: stepHandler())
            status = .success(L10n.installResultSuccess_fmt.formatted(options.carrier, options.transport))
            return result
        } catch {
            LogStore.shared.log(.provisioning, "✗ Add carrier failed: \(error.localizedDescription)")
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    /// Lists the deployed carrier configs (primary + siblings) for the host
    /// anchored by `baseContainer`. Read-only and status-silent (the
    /// probeReadiness convention) — safe to call on every card refresh.
    func listCarriers(on host: ServerHost, secret: SSHSecret,
                      baseContainer: String) async throws -> [SSHRunner.CarrierInfo] {
        LogStore.shared.startSession(.provisioning)
        try await ensureReachable(host)
        let output = try await SSHRunner._withConnection(host: host, secret: secret) { client in
            try await SSHRunner._execute(client: client, label: "list carriers",
                                         command: SSHRunner.carrierListScript(baseContainerName: baseContainer))
        }
        return SSHRunner.parseCarrierList(from: output)
    }

    /// Removes a sibling carrier (container + its server-<carrier>.yaml).
    /// Never touches the primary — removeCarrierScript always targets
    /// `<base>-<carrier>`.
    /// #469: kept for callers that only know the carrier.
    func removeCarrier(on host: ServerHost, secret: SSHSecret,
                       baseContainer: String, carrier: String) async throws {
        try await removeCarrier(on: host, secret: secret, baseContainer: baseContainer,
                                container: SSHRunner.siblingContainerName(base: baseContainer, carrier: carrier),
                                configFile: SSHRunner.carrierYAMLFile(carrier))
    }

    /// #469: the row names its container and its config file; delete exactly
    /// those (see `SSHRunner.removeCarrierScript(baseContainer:container:configFile:)`).
    func removeCarrier(on host: ServerHost, secret: SSHSecret,
                       baseContainer: String, container: String, configFile: String) async throws {
        status = .running(L10n.provisioningUninstallSSH.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Remove carrier on \(host.host): \(container) (\(configFile))")
        do {
            try await ensureReachable(host)
            let output = try await SSHRunner._withConnection(host: host, secret: secret) { client in
                try await SSHRunner._execute(client: client, label: "remove carrier",
                                             command: SSHRunner.removeCarrierScript(baseContainer: baseContainer,
                                                                                    container: container,
                                                                                    configFile: configFile))
            }
            guard SSHRunner.extract(key: "OLCRTC_CARRIER_REMOVED", from: output) == "ok" else {
                throw ProvisionError.sshCommand("remove carrier — \(String(output.suffix(300)))")
            }
            status = .success(L10n.uninstallResultSuccess.localized())
        } catch {
            LogStore.shared.log(.provisioning, "✗ Remove carrier failed: \(error.localizedDescription)")
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func reboot(on host: ServerHost, secret: SSHSecret) async throws {
        status = .running(L10n.provisioningRebootSSH.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Reboot on \(host.host)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.reboot(host: host, secret: secret,
                                        onStep: stepHandler())
            status = .success(L10n.rebootResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // MARK: Bot control (#418)

    /// Deploys (or re-deploys, replacing any existing one) a control bot on the
    /// host as a systemd service.
    func deployBot(on host: ServerHost, secret: SSHSecret, config: BotDeployConfig) async throws {
        status = .running(L10n.botDeploying.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning,
            "→ Deploy bot \(config.marker) (\(config.platform.rawValue)) on \(host.host)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.deployBot(host: host, secret: secret,
                                          config: config, onStep: stepHandler())
            status = .success(L10n.botDeploySuccess.localized())
        } catch {
            LogStore.shared.log(.provisioning, "✗ Deploy bot failed: \(error.localizedDescription)")
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    /// Detects bots on the host by probing every Settings bot name (`markers`)
    /// plus anything already in the fixed bot dir. Read-only.
    func checkBots(on host: ServerHost, secret: SSHSecret, markers: [String]) async throws -> [DeployedBot] {
        status = .running(L10n.botChecking.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Check bots on \(host.host) (\(markers.count) name(s))")
        do {
            try await ensureReachable(host)
            let found = try await SSHRunner.checkBots(host: host, secret: secret,
                                                      markers: markers, onStep: stepHandler())
            LogStore.shared.log(.provisioning, "✓ Found \(found.count) bot(s) on \(host.host)")
            status = .idle
            return found
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func removeBot(on host: ServerHost, secret: SSHSecret, marker: String) async throws {
        status = .running(L10n.botRemoving.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Remove bot \(marker) on \(host.host)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.removeBot(host: host, secret: secret,
                                          marker: marker, onStep: stepHandler())
            status = .success(L10n.botRemoveSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    /// #338: HH:mm stamp for the container-fetch session divider (static —
    /// per-call DateFormatter allocation is the #203 anti-pattern).
    private static let fetchStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private func stepHandler() -> @Sendable (String) -> Void {
        return { [weak self] step in
            Task { @MainActor in self?.status = .running(step) }
        }
    }
}

// SSH transport moved to SSHRunner.swift on 2026-05-16.
