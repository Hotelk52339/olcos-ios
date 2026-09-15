import Foundation

// MARK: - Steps

/// The five screens of the add-server wizard, in order.
enum AddServerStep: Int, CaseIterable, Identifiable, Sendable {
    case access, check, protocols, room, install

    var id: Int { rawValue }

    var title: L10n {
        switch self {
        case .access:    return .addFlowStepAccess
        case .check:     return .addFlowStepCheck
        case .protocols: return .addFlowStepProtocols
        case .room:      return .addFlowStepRoom
        case .install:   return .addFlowStepInstall
        }
    }

    var systemImage: String {
        switch self {
        case .access:    return "key.horizontal"
        case .check:     return "waveform.path.ecg"
        case .protocols: return "point.3.connected.trianglepath.dotted"
        case .room:      return "door.left.hand.open"
        case .install:   return "shippingbox"
        }
    }

    var next: AddServerStep? { AddServerStep(rawValue: rawValue + 1) }
    var previous: AddServerStep? { AddServerStep(rawValue: rawValue - 1) }
}

// MARK: - Step 1: access draft

/// Everything the user types on the Access step. The secret fields live here
/// only for the lifetime of the sheet; `makeSecret()` is the single way out and
/// the caller hands the result straight to `ServerHostStore.add(_:secret:)`,
/// which writes it to Keychain.
struct AddServerAccessDraft: Equatable {
    var label = ""
    var host = ""
    var port = "22"
    var username = "root"
    var authMethod: SSHAuthMethod = .password
    var password = ""
    var keyText = ""
    var passphrase = ""

    enum FieldError: Equatable {
        case labelMissing, labelDuplicate
        case hostMissing
        case portInvalid
        case userMissing
        case passwordMissing
        case keyMissing
        case keyUnsupported(SSHKeyAnalyzer.Detection)
        case passphraseMissing

        var message: String {
            switch self {
            case .labelMissing:      return L10n.addFlowLabelMissing.localized()
            case .labelDuplicate:    return L10n.duplicateServerNameError.localized()
            case .hostMissing:       return L10n.addFlowHostInvalid.localized()
            case .portInvalid:       return L10n.addFlowPortInvalid.localized()
            case .userMissing:       return L10n.addFlowUserMissing.localized()
            case .passwordMissing:   return L10n.addFlowPasswordMissing.localized()
            case .keyMissing:        return L10n.addFlowKeyMissing.localized()
            case .passphraseMissing: return L10n.addFlowPassphraseMissing.localized()
            case .keyUnsupported(let d):
                switch d {
                case .ecdsa:             return L10n.sshKeyErrorECDSA.localized()
                case .unsupportedFormat: return L10n.sshKeyErrorUnsupportedFormat.localized()
                default:                 return L10n.sshKeyErrorNotAKey.localized()
                }
            }
        }
    }

    var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 1…65535 or nil.
    static func validPort(_ text: String) -> Int? {
        guard let p = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else {
            return nil
        }
        return p
    }

    var keyDetection: SSHKeyAnalyzer.Detection? {
        keyText.isEmpty ? nil : SSHKeyAnalyzer.detect(keyText)
    }

    /// Every problem on the step. Empty == the step can advance.
    func validate(otherLabels: [String]) -> [FieldError] {
        var errors: [FieldError] = []
        let name = trimmedLabel
        if name.isEmpty {
            errors.append(.labelMissing)
        } else if otherLabels.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            errors.append(.labelDuplicate)
        }
        if trimmedHost.isEmpty { errors.append(.hostMissing) }
        if Self.validPort(port) == nil { errors.append(.portInvalid) }
        if trimmedUser.isEmpty { errors.append(.userMissing) }
        switch authMethod {
        case .password:
            if password.isEmpty { errors.append(.passwordMissing) }
        case .privateKey:
            if let detection = keyDetection {
                if !detection.isSupported {
                    errors.append(.keyUnsupported(detection))
                } else if detection.isEncrypted && passphrase.isEmpty {
                    errors.append(.passphraseMissing)
                }
            } else {
                errors.append(.keyMissing)
            }
        }
        return errors
    }

    func makeHost() -> ServerHost? {
        guard let p = Self.validPort(port), !trimmedHost.isEmpty, !trimmedLabel.isEmpty else { return nil }
        var h = ServerHost(label: trimmedLabel, host: trimmedHost)
        h.port = p
        h.username = trimmedUser.isEmpty ? "root" : trimmedUser
        h.authMethod = authMethod
        return h
    }

    func makeSecret() -> SSHSecret? {
        switch authMethod {
        case .password:
            return password.isEmpty ? nil : .password(password)
        case .privateKey:
            guard let detection = keyDetection, detection.isSupported else { return nil }
            return .privateKey(text: keyText, passphrase: passphrase.isEmpty ? nil : passphrase)
        }
    }
}

// MARK: - Step 2: what the server told us

enum AddServerContainerRuntime: String, Equatable, Sendable {
    case podman, docker
}

struct AddServerHostFacts: Equatable, Sendable {
    var osName: String?
    var arch: String?
    var runtime: AddServerContainerRuntime?
    var existing: [String] = []   // container names of olcOS installs already on the box

    /// One round-trip: os-release, kernel/arch, runtime, existing containers.
    /// Every section is prefixed so the parser does not depend on line order.
    static let script: String = """
    printf 'OS=%s\\n' "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-$NAME}")"
    printf 'ARCH=%s\\n' "$(uname -m 2>/dev/null)"
    if command -v podman >/dev/null 2>&1; then printf 'RUNTIME=podman\\n'; \
    elif command -v docker >/dev/null 2>&1; then printf 'RUNTIME=docker\\n'; \
    else printf 'RUNTIME=none\\n'; fi
    (podman ps -a --filter 'name=olcrtc-server-' --format 'CONTAINER={{.Names}}' 2>/dev/null \
      || docker ps -a --filter 'name=olcrtc-server-' --format 'CONTAINER={{.Names}}' 2>/dev/null) || true
    """

    static func parse(_ output: String) -> AddServerHostFacts {
        var facts = AddServerHostFacts()
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "OS":        facts.osName = value.isEmpty ? nil : value
            case "ARCH":      facts.arch = value.isEmpty ? nil : value
            case "RUNTIME":   facts.runtime = AddServerContainerRuntime(rawValue: value)
            case "CONTAINER": if value.hasPrefix("olcrtc-server-") { facts.existing.append(value) }
            default: break
            }
        }
        return facts
    }
}

enum AddServerCheckState: Equatable {
    case idle
    case running
    case done(AddServerHostFacts)
    case failed(String)

    var facts: AddServerHostFacts? {
        if case .done(let f) = self { return f }
        return nil
    }
    var isDone: Bool { facts != nil }
    var isRunning: Bool { self == .running }
}

/// What the host-key card says before/after the first SSH contact.
enum AddServerTrustState: Equatable {
    case firstContact, known, mismatch

    static func current(host: String, port: Int) -> AddServerTrustState {
        let store = SSHHostKeyTrustStore.shared
        if store.hasMismatch(host: host, port: port) { return .mismatch }
        return store.hasTrust(host: host, port: port) ? .known : .firstContact
    }
}

// MARK: - Step 3: carriers & transports

/// Upstream's guidance (docs/about.md): "Recommended start: jitsi + datachannel.
/// Alternative: wbstream + vp8channel." Telemost needs a Yandex account and
/// carries traffic as VP8. Nothing else is claimed.
enum AddServerCarrierBadge: Equatable, Sendable {
    case recommended, alternative, none

    var title: L10n? {
        switch self {
        case .recommended: return .addFlowBadgeRecommended
        case .alternative: return .addFlowBadgeAlternative
        case .none:        return nil
        }
    }
}

struct AddServerCarrierPlan: Equatable {
    /// Carriers in the order the user picked them; the first is the primary
    /// install, the rest are added to the same container base.
    var selected: [String] = []
    var transport: [String: String] = [:]

    var primary: String? { selected.first }
    var extras: [String] { Array(selected.dropFirst()) }
    var isEmpty: Bool { selected.isEmpty }

    static let defaultPlan = AddServerCarrierPlan(selected: ["jitsi"], transport: ["jitsi": "datachannel"])

    static func badge(for carrier: String) -> AddServerCarrierBadge {
        switch carrier {
        case "jitsi":    return .recommended
        case "wbstream": return .alternative
        default:         return .none
        }
    }

    static func recommendedTransport(for carrier: String) -> String {
        CarrierTransportMatrix.defaultTransport(for: carrier)
    }

    static func descriptionKey(forCarrier carrier: String) -> L10n {
        switch carrier {
        case "telemost": return .carrierTelemostDesc
        case "wbstream": return .carrierWbstreamDesc
        default:         return .carrierJitsiDesc
        }
    }

    static func descriptionKey(forTransport transport: String) -> L10n {
        switch transport {
        case "vp8channel":   return .transportVp8channelDesc
        case "seichannel":   return .transportSeichannelDesc
        case "videochannel": return .transportVideochannelDesc
        default:             return .transportDatachannelDesc
        }
    }

    func transport(for carrier: String) -> String {
        transport[carrier] ?? Self.recommendedTransport(for: carrier)
    }

    mutating func toggle(_ carrier: String) {
        if let i = selected.firstIndex(of: carrier) {
            selected.remove(at: i)
        } else {
            selected.append(carrier)
            if transport[carrier] == nil { transport[carrier] = Self.recommendedTransport(for: carrier) }
        }
    }

    mutating func makePrimary(_ carrier: String) {
        guard let i = selected.firstIndex(of: carrier), i != 0 else { return }
        selected.remove(at: i)
        selected.insert(carrier, at: 0)
    }

    /// Transports the matrix does not mark as failing for this carrier.
    static func transportOptions(for carrier: String) -> [String] {
        CarrierTransportMatrix.transports.filter {
            CarrierTransportMatrix.compat(carrier: carrier, transport: $0) != .fail
        }
    }
}

// MARK: - Step 4: rooms

struct AddServerRoomDraft: Equatable {
    /// Telemost: filled by `TelemostRoomService`, never typed by hand here.
    var telemostRoomID = ""
    var telemostRoomURI = ""
    /// Jitsi: `https://<instance>` + short room name (empty → server picks).
    var jitsiBaseURL = AppConstants.defaultJitsiBaseURL
    var jitsiRoomName = ""
    /// WB Stream: room id + optional account token (needed for DataChannel).
    var wbRoomID = ""
    var wbToken = ""

    enum RoomError: Equatable { case missing(carrier: String) }

    func validate(plan: AddServerCarrierPlan) -> [RoomError] {
        var errors: [RoomError] = []
        for carrier in plan.selected {
            switch carrier {
            case "telemost":
                if telemostRoomID.isEmpty { errors.append(.missing(carrier: carrier)) }
            case "wbstream":
                if wbRoomID.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.missing(carrier: carrier)) }
            case "jitsi":
                if jitsiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty { errors.append(.missing(carrier: carrier)) }
            default: break
            }
        }
        return errors
    }
}

// MARK: - Step 5: install options from the plan

extension AddServerCarrierPlan {
    /// Room IDs flow into `InstallOptions.roomID`, which `SSHRunner.installEnv`
    /// turns into `OLCRTC_ROOM_ID`. Everything the sheet does not expose keeps
    /// the `InstallOptions` defaults (SEI tuning from Settings).
    func installOptions(rooms: AddServerRoomDraft) -> (primary: InstallOptions, extras: [InstallOptions])? {
        guard let primary = primary else { return nil }
        func options(for carrier: String) -> InstallOptions {
            var o = InstallOptions(carrier: carrier, transport: transport(for: carrier), roomID: "")
            switch carrier {
            case "telemost":
                o.roomID = TelemostRoomService.normalizedRoomInput(rooms.telemostRoomID)
            case "jitsi":
                let base = rooms.jitsiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                o.jitsiBaseURL = base.isEmpty ? AppConstants.defaultJitsiBaseURL : base
                o.roomID = rooms.jitsiRoomName.components(separatedBy: .whitespacesAndNewlines).joined()
            case "wbstream":
                o.roomID = rooms.wbRoomID.components(separatedBy: .whitespacesAndNewlines).joined()
                o.wbToken = rooms.wbToken.trimmingCharacters(in: .whitespacesAndNewlines)
            default: break
            }
            return o
        }
        return (options(for: primary), extras.map(options(for:)))
    }
}
