import XCTest
@testable import olcrtc_ios

// Pins the contract for `CarrierTransportMatrix.requiresRoomID`.
// The YAML binary requires an explicit room ID for every carrier, so
// `autoGeneratesRoomID` is empty. If anyone flips the defensive default
// (unknown carrier → requires) or re-adds an auto-gen carrier by accident,
// these tests fail.

final class CarrierTransportMatrixTests: XCTestCase {

    func testEveryKnownCarrierRequiresRoomID() {
        for carrier in CarrierTransportMatrix.carriers {
            XCTAssertTrue(
                CarrierTransportMatrix.requiresRoomID(carrier: carrier),
                "expected \(carrier) to require a room ID"
            )
        }
    }

    func testUnknownCarrierRequiresRoomID() {
        // Defensive default: a carrier we haven't catalogued falls through to
        // "requires" because the server will reject it anyway. Set.contains
        // returns false for unknowns, so the function naturally defaults to
        // "requires" without an extra `if`.
        XCTAssertTrue(CarrierTransportMatrix.requiresRoomID(carrier: "unknown-future-carrier"))
    }

    func testAutoGenSetIsEmpty() {
        // The YAML binary requires an explicit room ID for every carrier, so
        // no carrier auto-generates one. When #226 wires Jitsi room-URL
        // auto-generation, add "jitsi" here and match it in scripts/srv.sh.
        XCTAssertTrue(CarrierTransportMatrix.autoGeneratesRoomID.isEmpty)
    }

    // #284: cells re-derived from upstream docs/settings.md; #434: re-synced to
    // the E2E table in `olcrtc-upstream/internal/e2e/tunnel_test.go` at master
    // (submodule pin f616f57 — jitsi returns ExpectPass for every transport).
    // #470: the FULL 12-cell snapshot. Nine cells were pinned and three
    // (telemost/videochannel, wbstream/seichannel, wbstream/videochannel) were
    // not, so a submodule bump or a stray edit flipping one of them — which
    // disables a chip and changes `failoverRank` — left every assertion green.
    // AGENTS.md names this test as the sole guard of the hand-synced table, so
    // it iterates carriers × transports: any cell change fails here. Update the
    // table and this snapshot together on every submodule bump.
    func testMatrixMatchesUpstream() {
        let expected: [String: [String: Compat]] = [
            "telemost": ["datachannel": .fail,        "vp8channel": .recommended,
                         "seichannel":  .fail,        "videochannel": .ok],
            "wbstream": ["datachannel": .question,    "vp8channel": .recommended,
                         "seichannel":  .ok,          "videochannel": .ok],
            "jitsi":    ["datachannel": .recommended, "vp8channel": .ok,
                         "seichannel":  .ok,          "videochannel": .ok],   // #434 was: sei/video .fail
        ]
        // The axes themselves are part of the contract (a 4th transport or a
        // 4th carrier must land in the table AND here).
        XCTAssertEqual(Set(CarrierTransportMatrix.carriers), Set(expected.keys))
        XCTAssertEqual(Set(CarrierTransportMatrix.transports), Set(expected["telemost"]!.keys))
        for carrier in CarrierTransportMatrix.carriers {
            for transport in CarrierTransportMatrix.transports {
                XCTAssertEqual(CarrierTransportMatrix.compat(carrier: carrier, transport: transport),
                               expected[carrier]?[transport],
                               "\(carrier)/\(transport) drifted from the upstream snapshot")
            }
        }
        XCTAssertEqual(CarrierTransportMatrix.compat(carrier: "nope", transport: "datachannel"), .unknown)
    }

    // The pre-selected transport for each carrier must be its recommended cell.
    func testDefaultTransportIsTheRecommendedCell() {
        for carrier in CarrierTransportMatrix.carriers {
            let t = CarrierTransportMatrix.defaultTransport(for: carrier)
            XCTAssertEqual(CarrierTransportMatrix.compat(carrier: carrier, transport: t), .recommended,
                           "default transport for \(carrier) should be its recommended cell")
        }
    }

    // (audit) transport gating: the sheets map matrix ✗ cells to disabled
    // OlcOptions carrying a VoiceOver reason; every other cell stays enabled.
    // Also pins the ADDITIVE OlcOption API — `disabled`/`disabledReason` must
    // keep their defaults so pre-gating `OlcOption(value:label:)` call sites
    // (Settings presets, Logs host picker, segments) keep compiling unchanged.
    //
    // #470 was: `testFailCellsProduceDisabledOptionsWithReason`, which built the
    // `OlcOption(disabled: fails, disabledReason: fails ? … : nil)` mapping
    // ITSELF and then asserted on its own arguments — a tautology that never
    // touched the three private copies of that mapping in InstallOptionsView,
    // AddConnectionView and ReconfigureOptionsView (invert the gate there and it
    // still passed). The ✗ cells are pinned by the full snapshot above; the
    // sheet mapping needs ONE shared `CarrierTransportMatrix.transportOptions(
    // for:)` the three sheets call before it can be asserted here at all.
    func testOlcOptionGatingFieldsDefaultToEnabled() {
        // Additive-defaults contract: the original initializer shape yields an
        // enabled option with no reason.
        let plain = OlcOption(value: "x", label: "X")
        XCTAssertFalse(plain.disabled)
        XCTAssertNil(plain.disabledReason)
        // And the gating shape round-trips its fields (memberwise, not derived).
        let gated = OlcOption(value: "y", label: "Y", disabled: true, disabledReason: "why")
        XCTAssertTrue(gated.disabled)
        XCTAssertEqual(gated.disabledReason, "why")
    }

    // #470: the sheets' gating IS the matrix. `.fail` cells are disabled with a
    // reason; every other cell is enabled — checked cell by cell against
    // `compat`, not against a copy of the option list.
    func testTransportOptionsGateExactlyTheFailCells() {
        for carrier in CarrierTransportMatrix.carriers {
            let opts = CarrierTransportMatrix.transportOptions(for: carrier)
            XCTAssertEqual(opts.map { $0.value }, CarrierTransportMatrix.transports, carrier)
            for opt in opts {
                let fails = CarrierTransportMatrix.compat(carrier: carrier, transport: opt.value) == .fail
                XCTAssertEqual(opt.disabled, fails, "\(carrier)/\(opt.value)")
                XCTAssertEqual(opt.disabledReason != nil, fails, "\(carrier)/\(opt.value)")
            }
        }
    }
}
