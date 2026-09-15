import Foundation
import SwiftUI

/// Result the wizard hands back to the presenter: exactly what the old
/// `AddServerHostView` + `InstallOptionsView` pair produced, in one call.
struct AddServerFlowOutcome {
    let host: ServerHost
    let secret: SSHSecret
    let primary: InstallOptions
    let extras: [InstallOptions]
}

/// Telemost room creation state on the Room step.
enum AddServerTelemostState: Equatable {
    case needsSignIn
    case creating
    case created(TelemostRoom)
    case failed(message: String, needsSignIn: Bool)
}

/// Where the Install step is.
enum AddServerInstallPhase: Equatable {
    case review
    case running(String)
    case success(String)
    case failure(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
    var isFinished: Bool {
        switch self {
        case .success, .failure: return true
        default: return false
        }
    }
}

/// All wizard state. SSH and network work runs in child tasks that the sheet
/// cancels on dismiss; the secret never leaves `access` except through
/// `makeOutcome()`.
@MainActor
final class AddServerFlowController: ObservableObject {
    @Published var step: AddServerStep = .access
    @Published var access = AddServerAccessDraft()
    @Published var showAccessErrors = false

    @Published var check: AddServerCheckState = .idle
    @Published var trust: AddServerTrustState = .firstContact

    @Published var plan: AddServerCarrierPlan = .defaultPlan

    @Published var rooms = AddServerRoomDraft()
    @Published var telemost: AddServerTelemostState = .needsSignIn
    @Published var showRoomErrors = false

    @Published var installPhase: AddServerInstallPhase = .review
    /// `serverStore.hosts` entry once the presenter saved it.
    @Published private(set) var savedHost: ServerHost?

    let otherLabels: [String]
    /// Owned here so the Room step and the controller see the same session state.
    let yandexStore = YandexSessionStore()

    private var checkTask: Task<Void, Never>?
    private var telemostTask: Task<Void, Never>?

    init(otherLabels: [String]) {
        self.otherLabels = otherLabels
    }

    // MARK: Navigation

    var accessErrors: [AddServerAccessDraft.FieldError] { access.validate(otherLabels: otherLabels) }
    var roomErrors: [AddServerRoomDraft.RoomError] { rooms.validate(plan: plan) }

    func canAdvance(from step: AddServerStep) -> Bool {
        switch step {
        case .access:    return accessErrors.isEmpty
        case .check:     return check.isDone && trust != .mismatch
        case .protocols: return !plan.isEmpty
        case .room:      return roomErrors.isEmpty
        case .install:   return false
        }
    }

    var canGoBack: Bool {
        step != .access && !installPhase.isRunning && !installPhase.isFinished
    }

    func advance() {
        switch step {
        case .access:
            showAccessErrors = true
            guard canAdvance(from: .access) else { return }
        case .room:
            showRoomErrors = true
            guard canAdvance(from: .room) else { return }
        default:
            guard canAdvance(from: step) else { return }
        }
        guard let next = step.next else { return }
        Haptics.tap()
        withAnimation(.snappy) { step = next }
        if next == .check, check == .idle { startCheck() }
        if next == .room { startTelemostIfNeeded() }
    }

    func goBack() {
        guard canGoBack, let prev = step.previous else { return }
        withAnimation(.snappy) { step = prev }
    }

    func cancelWork() {
        checkTask?.cancel()
        telemostTask?.cancel()
    }

    // MARK: Step 2 — SSH check

    func startCheck() {
        guard let host = access.makeHost(), let secret = access.makeSecret() else { return }
        checkTask?.cancel()
        check = .running
        trust = AddServerTrustState.current(host: host.host, port: host.port)
        checkTask = Task { [weak self] in
            let result = await AddServerProbe.run(host: host, secret: secret)
            guard let self, !Task.isCancelled else { return }
            self.trust = AddServerTrustState.current(host: host.host, port: host.port)
            switch result {
            case .success(let facts):
                self.check = .done(facts)
            case .failure(let error):
                self.check = .failed(error.localizedDescription)
            }
        }
    }

    /// The Access step changed → the previous check no longer applies.
    func invalidateCheck() {
        checkTask?.cancel()
        check = .idle
    }

    // MARK: Step 4 — Telemost room

    var needsTelemost: Bool { plan.selected.contains("telemost") }

    func startTelemostIfNeeded() {
        guard needsTelemost, rooms.telemostRoomID.isEmpty else { return }
        if yandexStore.hasSession { createTelemostRoom() } else { telemost = .needsSignIn }
    }

    /// Called by the Yandex login sheet with the raw session value; stored in
    /// Keychain by the store, never kept here.
    func yandexSignedIn(_ session: String) {
        guard yandexStore.save(session) else {
            telemost = .failed(message: L10n.telemostErrSessionRejected.localized(), needsSignIn: true)
            return
        }
        createTelemostRoom()
    }

    func createTelemostRoom() {
        telemostTask?.cancel()
        telemost = .creating
        telemostTask = Task { [weak self] in
            do {
                let room = try await TelemostRoomService.createRoom()
                guard let self, !Task.isCancelled else { return }
                self.rooms.telemostRoomID = room.id
                self.rooms.telemostRoomURI = room.uri
                self.telemost = .created(room)
                Haptics.success()
            } catch {
                guard let self, !Task.isCancelled else { return }
                let needsSignIn = (error as? TelemostRoomError)?.needsSignIn ?? false
                self.telemost = .failed(message: error.localizedDescription, needsSignIn: needsSignIn)
            }
        }
    }

    func switchYandexAccount() {
        telemostTask?.cancel()
        yandexStore.clear()
        rooms.telemostRoomID = ""
        rooms.telemostRoomURI = ""
        telemost = .needsSignIn
    }

    // MARK: Step 5 — outcome

    func makeOutcome() -> AddServerFlowOutcome? {
        guard let host = access.makeHost(), let secret = access.makeSecret(),
              let options = plan.installOptions(rooms: rooms) else { return nil }
        return AddServerFlowOutcome(host: host, secret: secret,
                                    primary: options.primary, extras: options.extras)
    }

    func markInstallStarted(host: ServerHost) {
        savedHost = host
        installPhase = .running(L10n.addFlowInstallRunning.localized())
    }

    /// Mirrors `Provisioner.status` into the wizard once the install started.
    func observe(_ status: ProvisionStatus) {
        guard savedHost != nil, !installPhase.isFinished else { return }
        switch status {
        case .idle: break
        case .running(let text): installPhase = .running(text)
        case .success(let text): installPhase = .success(text); Haptics.success()
        case .failure(let text): installPhase = .failure(text); Haptics.error()
        }
    }
}

// MARK: - SSH probe (step 2)

/// One SSH session: learn (or verify) the host key through the normal
/// `SSHRunner` path, then collect facts. Runs off the main actor.
enum AddServerProbe {
    static func run(host: ServerHost, secret: SSHSecret) async -> Result<AddServerHostFacts, Error> {
        do {
            let output = try await SSHRunner._withConnection(host: host, secret: secret) { client in
                try await SSHRunner._execute(client: client, label: "probe",
                                             command: AddServerHostFacts.script)
            }
            return .success(AddServerHostFacts.parse(output))
        } catch {
            return .failure(error)
        }
    }
}
