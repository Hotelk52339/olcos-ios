import XCTest
@testable import olcrtc_ios

// Round 2, subagent D: the redesigned health chip's text model
// (`HealthDisplay.chipText`, App/Models/NodeHealth.swift) and the pieces that
// let the Servers tab draw its first frame from memory — the protocol rows
// persisted inside `HostSnapshot`, the store's resolved-credential cache, and
// the deferral helper. Everything here is pure or store-level; the view-side
// wiring (ProtocolRowView / HealthChip.swift / ServersView) is documented at
// its sites and in dev-notes/round2-report-D.md.
@MainActor
final class Round2HealthChipTests: XCTestCase {

    private var savedLanguage = ""
    private let snapshotKey = "olcrtc_host_snapshot_v1"
    private var savedSnapshots: Data?

    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
        savedSnapshots = UserDefaults.standard.data(forKey: snapshotKey)
    }

    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        if let savedSnapshots {
            UserDefaults.standard.set(savedSnapshots, forKey: snapshotKey)
        } else {
            UserDefaults.standard.removeObject(forKey: snapshotKey)
        }
        super.tearDown()
    }

    // MARK: chipText — one primary line, an optional age, never a sentence

    private let everyState: [HealthDisplay] = [
        .never, .checking,
        .verified(ms: 146, age: 20), .verified(ms: nil, age: 20),
        .fading(ms: 146, age: 600), .fading(ms: nil, age: 600),
        .handshakeOnly(age: 45),
        .broken(.keyMismatch, age: 300),
        .inconclusive(.hostUnreachable, age: 120),
        .stale(age: 7200),
    ]

    func testEveryStateHasANonEmptySingleLinePrimary() {
        for state in everyState {
            let text = state.chipText
            XCTAssertFalse(text.primary.isEmpty, "\(state) has an empty primary line")
            XCTAssertFalse(text.primary.contains("\n"), "\(state) primary must be one line")
            if let age = text.secondary {
                XCTAssertFalse(age.isEmpty, "\(state) secondary must not be empty when present")
                XCTAssertFalse(age.contains("\n"))
            }
        }
    }

    func testStatesWithoutAClockHaveNoSecondary() {
        XCTAssertNil(HealthDisplay.never.chipText.secondary)
        XCTAssertNil(HealthDisplay.checking.chipText.secondary)
        for state in everyState where !state.isChecking && state != .never {
            XCTAssertNotNil(state.chipText.secondary, "\(state) is dated and must show an age")
        }
    }

    func testVerifiedPrimaryIsTheLatencyAndAgeIsShortForm() {
        let text = HealthDisplay.verified(ms: 146, age: 20).chipText
        XCTAssertEqual(text.primary, L10n.healthLatencyMs_fmt.formatted(146))
        XCTAssertEqual(text.secondary, L10n.ageNowShort.localized())
        XCTAssertEqual(HealthDisplay.verified(ms: 146, age: 5 * 60).chipText.secondary,
                       L10n.ageMinutes_fmt.formatted(5))
    }

    func testVerifiedWithoutLatencyFallsBackToTheVerdictWord() {
        XCTAssertEqual(HealthDisplay.verified(ms: nil, age: 20).chipText.primary,
                       L10n.healthVerified.localized())
    }

    /// The colour-blind contract: present tense and past tense differ by word.
    func testFadingReadsAsPastTenseNotAsTheSameNumber() {
        let live = HealthDisplay.verified(ms: 146, age: 20).chipText.primary
        let faded = HealthDisplay.fading(ms: 146, age: 600).chipText.primary
        XCTAssertNotEqual(live, faded)
        XCTAssertTrue(faded.contains(L10n.healthLatencyMs_fmt.formatted(146)),
                      "the faded line still carries the last measured value")
        XCTAssertEqual(HealthDisplay.fading(ms: nil, age: 600).chipText.primary,
                       L10n.healthFading.localized())
    }

    func testBrokenAndInconclusiveUseTheReasonHeadline() {
        XCTAssertEqual(HealthDisplay.broken(.keyMismatch, age: 300).chipText.primary,
                       HealthReason.keyMismatch.headline)
        XCTAssertEqual(HealthDisplay.inconclusive(.hostUnreachable, age: 120).chipText.primary,
                       HealthReason.hostUnreachable.headline)
    }

    func testNeutralStatesUseTheirOwnWords() {
        XCTAssertEqual(HealthDisplay.never.chipText.primary, L10n.healthChipNotChecked.localized())
        XCTAssertEqual(HealthDisplay.checking.chipText.primary, L10n.healthChecking.localized())
        XCTAssertEqual(HealthDisplay.handshakeOnly(age: 45).chipText.primary,
                       L10n.healthChipNoData.localized())
        XCTAssertEqual(HealthDisplay.stale(age: 7200).chipText.primary, L10n.healthStale.localized())
    }

    /// The one-line `chipLabel` other callers pin is untouched by the redesign.
    func testLegacyChipLabelStillAnswers() {
        // The legacy label is "48 ms · now": latency first, then the short age.
        XCTAssertTrue(HealthDisplay.verified(ms: 48, age: 0).chipLabel
                        .hasPrefix(L10n.healthLatencyMs_fmt.formatted(48)))
        XCTAssertEqual(HealthDisplay.never.chipLabel, L10n.healthChipNever.localized())
    }

    // MARK: The glyph fallback keeps one silhouette per state

    func testGlyphsAreDistinctAcrossStates() {
        let symbols = everyState.map { OlcHealthGlyph.symbol(for: $0) }
        // verified(ms:) and verified(ms: nil) share a state, as do the two fadings.
        XCTAssertEqual(Set(symbols).count, 8)
    }

    // MARK: HostSnapshot carries the protocol rows (non-secret) — round trip

    private func row(_ container: String, status: ContainerStatus, primary: Bool = false) -> SSHRunner.CarrierInfo {
        SSHRunner.CarrierInfo(file: primary ? "server.yaml" : "server-\(container).yaml",
                              provider: "telemost", transport: "vp8", room: "room-\(container)",
                              container: container, status: status, isPrimary: primary)
    }

    func testCarrierMirrorRoundTripsEveryStatus() {
        for status in [ContainerStatus.running("Up 2 hours"),
                       .stopped("Exited (137) 5 minutes ago"),
                       .notFound] {
            let info = row("c", status: status, primary: true)
            let mirrored = HostSnapshotCarrier(info).carrierInfo
            XCTAssertEqual(mirrored, info, "\(status) must survive the snapshot")
        }
        XCTAssertEqual(HostSnapshotCarrier.rawStatus(.notFound), "")
        XCTAssertEqual(HostSnapshotCarrier.rawStatus(.running("Up 1 second")), "Up 1 second")
    }

    func testSnapshotWithRowsEncodesNoSecretFields() throws {
        var snap = HostSnapshot(base: .running, probedAt: Date())
        snap.carriers = [HostSnapshotCarrier(row("olcrtc", status: .running("Up 2 hours"), primary: true))]
        snap.carriersReadAt = Date()
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(["k": snap]), encoding: .utf8))
        for forbidden in ["password", "privateKey", "passphrase", "secret", "host\"", "user\""] {
            XCTAssertFalse(json.contains(forbidden), "snapshot must not encode \(forbidden)")
        }
    }

    func testLegacySnapshotWithoutRowsDecodesWithNilRows() throws {
        let legacy = """
        {"k":{"base":"running","probedAt":\(Date().timeIntervalSinceReferenceDate),"pingMs":42}}
        """
        let decoded = HealthCoordinator.decodeHostSnapshots(Data(legacy.utf8), now: Date())
        XCTAssertEqual(decoded["k"]?.base, .running)
        XCTAssertNil(decoded["k"]?.carriers)
        XCTAssertNil(decoded["k"]?.carriersReadAt)
    }

    func testSeededRowsSkipNilAndEmptyListings() {
        var snap = HostSnapshot(base: .running, probedAt: Date())
        XCTAssertNil(ServersView.seededRows(snap))
        snap.carriers = []
        XCTAssertNil(ServersView.seededRows(snap), "an empty listing is re-read, never asserted")
        snap.carriers = [HostSnapshotCarrier(row("a", status: .running("Up 1 hour"), primary: true)),
                         HostSnapshotCarrier(row("b", status: .stopped("Exited (0) 2 hours ago")))]
        let seeded = ServersView.seededRows(snap)
        XCTAssertEqual(seeded?.map(\.container), ["a", "b"])
        XCTAssertEqual(seeded?.first?.status, .running("Up 1 hour"))
        XCTAssertEqual(seeded?.last?.status, .stopped("Exited (0) 2 hours ago"))
    }

    func testCoordinatorRoundTripsRowsInMemory() {
        let health = HealthCoordinator(loadPersisted: false)
        let id = UUID()
        var snap = HostSnapshot(base: .running, probedAt: Date())
        snap.carriers = [HostSnapshotCarrier(row("c", status: .running("Up 2 hours"), primary: true))]
        health.noteHostSnapshot(snap, for: id)
        XCTAssertEqual(health.hostSnapshot(for: id)?.carriers?.count, 1)
        health.forgetHost(id)
        XCTAssertNil(health.hostSnapshot(for: id))
    }

    // MARK: The store's in-memory credential cache

    private var storeDefaults: UserDefaults {
        UserDefaults(suiteName: "Round2HealthChipTests.\(UUID().uuidString)")!
    }

    func testSecretCacheServesAfterFirstReadAndDropsOnWriteAndRemove() {
        let store = ServerHostStore(defaults: storeDefaults)
        let host = ServerHost(label: "Cache", host: "example.invalid")
        defer { store.remove(at: IndexSet(store.hosts.indices.filter { store.hosts[$0].id == host.id })) }

        store.add(host, secret: .password("first"))
        XCTAssertEqual(store.secret(for: host), .password("first"))
        // Served from memory now; a second read must agree with the first.
        XCTAssertEqual(store.secret(for: host), .password("first"))

        // A write drops the cached value, so the new credential is what comes back.
        store.update(host, secret: .password("second"))
        XCTAssertEqual(store.secret(for: host), .password("second"))
        store.update(host, password: "third")
        XCTAssertEqual(store.secret(for: host), .password("third"))

        // Invalidation forgets, the Keychain still answers.
        store.invalidateSecrets()
        XCTAssertEqual(store.secret(for: host), .password("third"))

        // Removal wipes the Keychain AND the cache: nothing lingers in memory.
        store.remove(at: IndexSet(store.hosts.indices.filter { store.hosts[$0].id == host.id }))
        XCTAssertNil(store.secret(for: host))
    }

    func testSecretCacheKeyIncludesAuthMethod() {
        let store = ServerHostStore(defaults: storeDefaults)
        var host = ServerHost(label: "Method", host: "example.invalid")
        store.add(host, secret: .password("pw"))
        defer { store.remove(at: IndexSet(store.hosts.indices.filter { store.hosts[$0].id == host.id })) }
        XCTAssertEqual(store.secret(for: host), .password("pw"))
        // Same id, different method: a miss, not the cached password.
        host.authMethod = .privateKey
        XCTAssertNil(store.secret(for: host))
    }

    // MARK: The first-frame deferral

    func testDeferPastFirstFrameReturnsTrueWhenNotCancelled() async {
        let started = Date()
        let ok = await ServersView.deferPastFirstFrame()
        XCTAssertTrue(ok)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started),
                                    Double(ServersView.firstFrameDeferMilliseconds) / 1000 - 0.05)
    }

    func testDeferPastFirstFrameReturnsFalseWhenCancelled() async {
        let task = Task { await ServersView.deferPastFirstFrame() }
        task.cancel()
        let ok = await task.value
        XCTAssertFalse(ok)
    }
}
