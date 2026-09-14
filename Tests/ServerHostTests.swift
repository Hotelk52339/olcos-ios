import XCTest
@testable import olcrtc_ios

// #295: per-server container log files are named "<logFilePrefix>_container.log",
// so the prefix must be filesystem-safe and unique per host. Covers the
// sanitisation helper and `AddServerHostView`'s duplicate-name check.

final class ServerHostTests: XCTestCase {

    // MARK: sanitizeLogFilePrefix

    func testSanitizeKeepsAlphanumerics() {
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("TWmsk1"), "TWmsk1")
    }

    func testSanitizeCollapsesPunctuationAndSpacesToUnderscore() {
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("TW Moscow #1"), "TW_Moscow_1")
    }

    func testSanitizeCollapsesConsecutiveSeparators() {
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("TW   Moscow ## 1"), "TW_Moscow_1")
    }

    func testSanitizeTrimsLeadingAndTrailingSeparators() {
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("  TW Moscow  "), "TW_Moscow")
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("#TW Moscow#"), "TW_Moscow")
    }

    // #323 was: empty/all-symbol labels all collapsed to the literal "server",
    // so two such hosts collided on one log file. Now each keeps the "server"
    // base but gets a stable hash suffix, so distinct labels stay distinct.
    func testSanitizeFallsBackToServerBaseWhenEmptyOrAllSymbols() {
        XCTAssertTrue(ServerHost.sanitizeLogFilePrefix("").hasPrefix("server_"))
        XCTAssertTrue(ServerHost.sanitizeLogFilePrefix("###").hasPrefix("server_"))
        XCTAssertTrue(ServerHost.sanitizeLogFilePrefix("   ").hasPrefix("server_"))
        // Distinct all-symbol labels no longer collapse to the same prefix.
        XCTAssertNotEqual(ServerHost.sanitizeLogFilePrefix("###"),
                          ServerHost.sanitizeLogFilePrefix("@@@"))
    }

    // #323: two differently-named Cyrillic hosts must NOT collide (the original
    // bug: both → "server"). The prefix must also stay byte-stable across calls
    // so the on-disk container-log filename survives app restarts.
    func testNonASCIILabelsGetDistinctStablePrefixes() {
        // Both pure-Cyrillic (no ASCII core) → "server_<hash>". (A label with an
        // ASCII digit/letter, e.g. "Москва-1", keeps that core instead — covered
        // by testMixedASCIINonASCIILabelKeepsCoreAndDisambiguates.)
        let a = ServerHost.sanitizeLogFilePrefix("Москва")
        let b = ServerHost.sanitizeLogFilePrefix("Питер")
        XCTAssertTrue(a.hasPrefix("server_"))
        XCTAssertTrue(b.hasPrefix("server_"))
        XCTAssertNotEqual(a, b, "distinct Cyrillic names must map to distinct log prefixes")
        // Deterministic — same input, same output (not Swift's salted hashValue).
        XCTAssertEqual(a, ServerHost.sanitizeLogFilePrefix("Москва"))
        // Filesystem-safe: only ASCII alphanumerics + underscore.
        XCTAssertTrue(a.allSatisfy { ($0.isASCII && $0.isLetter) || $0.isNumber || $0 == "_" })
    }

    // #323: a label that mixes ASCII with non-ASCII keeps its readable ASCII
    // core but is still disambiguated by the hash, so "Питер msk" and
    // "Москва msk" both keep "msk" yet don't collide.
    func testMixedASCIINonASCIILabelKeepsCoreAndDisambiguates() {
        let a = ServerHost.sanitizeLogFilePrefix("Питер msk")
        let b = ServerHost.sanitizeLogFilePrefix("Москва msk")
        XCTAssertTrue(a.hasPrefix("msk_"))
        XCTAssertTrue(b.hasPrefix("msk_"))
        XCTAssertNotEqual(a, b)
    }

    func testLogFilePrefixMatchesSanitizedLabel() {
        let host = ServerHost(label: "TW Moscow #1", host: "1.2.3.4")
        XCTAssertEqual(host.logFilePrefix, "TW_Moscow_1")
    }

    // MARK: AddServerHostView duplicate-name detection
    //
    // `isDuplicateLabel` is private to the view, so this exercises the same
    // logic via `ServerHost.sanitizeLogFilePrefix` directly: two labels are
    // "duplicates" if they're equal case-insensitively, OR their sanitised
    // prefixes collide.

    func testDistinctLabelsThatSanitizeToTheSamePrefixAreDuplicates() {
        let a = "TW Moscow-1"
        let b = "TW Moscow #1"
        XCTAssertEqual(
            ServerHost.sanitizeLogFilePrefix(a).lowercased(),
            ServerHost.sanitizeLogFilePrefix(b).lowercased(),
            "\(a) and \(b) must collide on their sanitised log-file prefix"
        )
    }

    func testCaseInsensitiveDuplicateLabels() {
        XCTAssertEqual("TW Moscow".lowercased(), "tw moscow".lowercased())
    }

    // MARK: #451 — authMethod Codable compatibility

    /// Hosts saved before key auth existed have no `authMethod` key in their
    /// UserDefaults JSON — they must keep decoding (nil → password behaviour).
    func testLegacyHostJSONWithoutAuthMethodDecodes() throws {
        let legacy = """
        {"id":"11111111-2222-3333-4444-555555555555","label":"TW","host":"1.2.3.4",
         "port":22,"username":"root"}
        """
        let host = try JSONDecoder().decode(ServerHost.self, from: Data(legacy.utf8))
        XCTAssertNil(host.authMethod)
        XCTAssertEqual(host.label, "TW")
    }

    func testAuthMethodRoundTripsThroughCodable() throws {
        var host = ServerHost(label: "key-host", host: "1.2.3.4")
        host.authMethod = .privateKey
        let data = try JSONEncoder().encode(host)
        let back = try JSONDecoder().decode(ServerHost.self, from: data)
        XCTAssertEqual(back.authMethod, .privateKey)
        // Raw values are the persisted contract — renaming a case would
        // silently drop stored hosts to nil on decode.
        XCTAssertEqual(SSHAuthMethod.password.rawValue, "password")
        XCTAssertEqual(SSHAuthMethod.privateKey.rawValue, "privateKey")
    }

    // MARK: #452 — extraConnectionIDs Codable compatibility

    /// Hosts saved before multi-carrier existed have no `extraConnectionIDs`
    /// key — they must keep decoding (nil), same convention as authMethod.
    func testLegacyHostJSONWithoutExtraConnectionIDsDecodes() throws {
        let legacy = """
        {"id":"11111111-2222-3333-4444-555555555555","label":"TW","host":"1.2.3.4",
         "port":22,"username":"root"}
        """
        let host = try JSONDecoder().decode(ServerHost.self, from: Data(legacy.utf8))
        XCTAssertNil(host.extraConnectionIDs)
    }

    func testExtraConnectionIDsRoundTripThroughCodable() throws {
        var host = ServerHost(label: "multi", host: "1.2.3.4")
        let ids = [UUID(), UUID()]
        host.extraConnectionIDs = ids
        let data = try JSONEncoder().encode(host)
        let back = try JSONDecoder().decode(ServerHost.self, from: data)
        XCTAssertEqual(back.extraConnectionIDs, ids)
    }
}

// MARK: - SSHKeyAnalyzerTests (#451)
//
// Detection drives the add-server key validation (accept ed25519/RSA, reject
// ECDSA with guidance, reveal the passphrase field for encrypted keys) and
// SSHRunner.authenticationMethod's parser pick. Fixtures are SYNTHETIC
// openssh-key-v1 containers built field-by-field — structurally valid headers
// with junk key material, so nothing here is (or ever was) a real private key;
// the detector never reads past the public-key type string anyway.

final class SSHKeyAnalyzerTests: XCTestCase {

    // MARK: Synthetic openssh-key-v1 fixture builder

    /// Assembles the unencrypted-prefix portion of an openssh-key-v1 blob:
    /// magic, cipher, kdf, kdf-options, key count, and a public-key blob whose
    /// first field is `keyType` — everything SSHKeyAnalyzer reads.
    private func opensshFixture(keyType: String,
                                cipher: String = "none",
                                kdf: String = "none") -> String {
        var blob = Data("openssh-key-v1\0".utf8)
        func appendString(_ d: Data) {
            var len = UInt32(d.count).bigEndian
            blob.append(Data(bytes: &len, count: 4))
            blob.append(d)
        }
        appendString(Data(cipher.utf8))
        appendString(Data(kdf.utf8))
        appendString(Data())                       // kdf options (empty for "none")
        var one = UInt32(1).bigEndian
        blob.append(Data(bytes: &one, count: 4))   // number of keys
        // Public-key blob: string keytype + junk "key material".
        var pub = Data()
        var typeLen = UInt32(keyType.utf8.count).bigEndian
        pub.append(Data(bytes: &typeLen, count: 4))
        pub.append(Data(keyType.utf8))
        pub.append(Data(repeating: 0x42, count: 32))
        appendString(pub)
        let b64 = blob.base64EncodedString()
        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(b64)
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    // MARK: Supported types

    func testDetectsUnencryptedEd25519() {
        XCTAssertEqual(SSHKeyAnalyzer.detect(opensshFixture(keyType: "ssh-ed25519")),
                       .ed25519(encrypted: false))
    }

    func testDetectsEncryptedEd25519() {
        // ssh-keygen's default passphrase protection: aes256-ctr + bcrypt.
        XCTAssertEqual(SSHKeyAnalyzer.detect(opensshFixture(keyType: "ssh-ed25519",
                                                            cipher: "aes256-ctr", kdf: "bcrypt")),
                       .ed25519(encrypted: true))
    }

    func testDetectsRSA() {
        XCTAssertEqual(SSHKeyAnalyzer.detect(opensshFixture(keyType: "ssh-rsa")),
                       .rsa(encrypted: false))
        XCTAssertEqual(SSHKeyAnalyzer.detect(opensshFixture(keyType: "ssh-rsa",
                                                            cipher: "aes128-ctr", kdf: "bcrypt")),
                       .rsa(encrypted: true))
    }

    func testDetectionSurvivesSurroundingWhitespace() {
        let padded = "\n  " + opensshFixture(keyType: "ssh-ed25519") + "\n\n"
        XCTAssertEqual(SSHKeyAnalyzer.detect(padded), .ed25519(encrypted: false))
    }

    // MARK: Rejections

    func testRejectsECDSAOpenSSHKey() {
        XCTAssertEqual(SSHKeyAnalyzer.detect(opensshFixture(keyType: "ecdsa-sha2-nistp256")),
                       .ecdsa)
    }

    func testRejectsECDSAPemArmor() {
        // SEC1 PEM ("EC PRIVATE KEY") is ECDSA by definition — reject with the
        // ECDSA guidance, not the generic format hint.
        let pem = """
        -----BEGIN EC PRIVATE KEY-----
        AAAA
        -----END EC PRIVATE KEY-----
        """
        XCTAssertEqual(SSHKeyAnalyzer.detect(pem), .ecdsa)
    }

    func testRejectsLegacyPEMFormats() {
        // Citadel parses only the OpenSSH text format — PKCS#1/PKCS#8 armors
        // need `ssh-keygen -p -o` conversion first.
        let pkcs1 = "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----"
        XCTAssertEqual(SSHKeyAnalyzer.detect(pkcs1), .unsupportedFormat)
        let pkcs8 = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"
        XCTAssertEqual(SSHKeyAnalyzer.detect(pkcs8), .unsupportedFormat)
    }

    func testRejectsPuTTYAndFIDOKeys() {
        XCTAssertEqual(SSHKeyAnalyzer.detect("PuTTY-User-Key-File-3: ssh-ed25519"),
                       .unsupportedFormat)
        XCTAssertEqual(SSHKeyAnalyzer.detect(opensshFixture(keyType: "sk-ssh-ed25519@openssh.com")),
                       .unsupportedFormat)
    }

    func testRejectsNonKeys() {
        XCTAssertEqual(SSHKeyAnalyzer.detect(""), .notAKey)
        XCTAssertEqual(SSHKeyAnalyzer.detect("hello world"), .notAKey)
        // A public-key line — the classic wrong paste.
        XCTAssertEqual(SSHKeyAnalyzer.detect("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ user@host"),
                       .notAKey)
        // OpenSSH armor around non-base64 garbage.
        let corrupt = "-----BEGIN OPENSSH PRIVATE KEY-----\n!!!not-base64!!!\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertEqual(SSHKeyAnalyzer.detect(corrupt), .notAKey)
        // Valid base64 that isn't an openssh-key-v1 container.
        let wrongMagic = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(Data("nonsense".utf8).base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertEqual(SSHKeyAnalyzer.detect(wrongMagic), .notAKey)
    }

    // MARK: Convenience flags used by the add-server sheet

    func testDetectionConvenienceFlags() {
        XCTAssertTrue(SSHKeyAnalyzer.Detection.ed25519(encrypted: true).isSupported)
        XCTAssertTrue(SSHKeyAnalyzer.Detection.ed25519(encrypted: true).isEncrypted)
        XCTAssertTrue(SSHKeyAnalyzer.Detection.rsa(encrypted: false).isSupported)
        XCTAssertFalse(SSHKeyAnalyzer.Detection.rsa(encrypted: false).isEncrypted)
        XCTAssertFalse(SSHKeyAnalyzer.Detection.ecdsa.isSupported)
        XCTAssertFalse(SSHKeyAnalyzer.Detection.unsupportedFormat.isSupported)
        XCTAssertFalse(SSHKeyAnalyzer.Detection.notAKey.isSupported)
    }
}
