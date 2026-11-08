import Foundation
import HSpaceTestSupport
import PreferencesTransfer
import Testing

private func schema() throws -> PreferenceSchema {
    try PreferenceSchema([
        "flag": .bool,
        "count": .integer(0...10),
        "dim": .number(0...0.3),
        "mode": .choice(["a", "b"]),
        "hex": .text(pattern: "[0-9A-F]{6}"),
        "names": .list(maxCount: 3, pattern: "[a-z]+"),
    ])
}

private func file(_ settings: String, format: String = PreferencesFile.format, version: Int = 1) -> Data {
    Data("{\"format\":\"\(format)\",\"version\":\(version),\"app\":\"1.0\",\"settings\":{\(settings)}}".utf8)
}

@Suite struct PreferenceSchemaTests {
    @Test func aSchemaCannotCarryASecret() {
        for key in ["archivePassword", "api_key", "authToken", "sshPassphrase", "Keychain.item", "client-secret"] {
            #expect(throws: PreferencesTransferError.self, "\(key)") { try PreferenceSchema([key: .bool]) }
        }
        #expect(!PreferenceSchema.looksSecret("archiveFormat"))
        #expect(!PreferenceSchema.looksSecret("kb.newTab"))
    }

    @Test func valuesAreCheckedAgainstTheirKind() throws {
        let s = try schema()
        #expect(s.validated("flag", .bool(true)) == .bool(true))
        #expect(s.validated("flag", .integer(1)) == nil)
        #expect(s.validated("count", .integer(10)) == .integer(10))
        #expect(s.validated("count", .integer(11)) == nil)
        #expect(s.validated("count", .number(2.5)) == nil)
        #expect(s.validated("dim", .integer(0)) == .number(0))
        #expect(s.validated("dim", .number(0.31)) == nil)
        #expect(s.validated("dim", .number(.nan)) == nil)
        #expect(s.validated("mode", .text("b")) == .text("b"))
        #expect(s.validated("mode", .text("c")) == nil)
        #expect(s.validated("hex", .text("00FF00")) == .text("00FF00"))
        #expect(s.validated("hex", .text("00FF00\n")) == nil)
        #expect(s.validated("hex", .text("x00FF00")) == nil)
        #expect(s.validated("names", .list(["a", "b"])) == .list(["a", "b"]))
        #expect(s.validated("names", .list(["a", "B"])) == nil)
        #expect(s.validated("names", .list(["a", "b", "c", "d"])) == nil)
        #expect(s.validated("other", .bool(true)) == nil)
    }
}

@Suite struct PreferencesFileTests {
    @Test func aWrittenFileReadsBackTheSame() throws {
        let values: [String: PreferenceValue] = ["flag": .bool(false), "count": .integer(3), "dim": .number(0.1),
                                                 "mode": .text("a"), "hex": .text("ABCDEF"), "names": .list(["x"])]
        let (data, left) = try PreferencesFile.encode(values, schema: try schema(), appVersion: "1.2")
        #expect(left.isEmpty)
        let document = try PreferencesFile.decode(data, schema: try schema())
        #expect(document.values == values)
        #expect(document.appVersion == "1.2")
    }

    @Test func exportLeavesOutUnknownBadAndSecretValues() throws {
        let values: [String: PreferenceValue] = ["flag": .bool(true), "count": .integer(99), "stranger": .bool(true),
                                                 "password": .text("hunter2")]
        let (data, left) = try PreferencesFile.encode(values, schema: try schema(), appVersion: "1")
        #expect(left == ["count", "password", "stranger"])
        #expect(!String(decoding: data, as: UTF8.self).contains("hunter2"))
        #expect(try PreferencesFile.decode(data, schema: try schema()).values == ["flag": .bool(true)])
    }

    @Test func anEmptySettingsListIsValid() throws {
        #expect(try PreferencesFile.decode(file(""), schema: try schema()).values.isEmpty)
    }

    @Test(arguments: [
        "\"flag\":true,\"count\":11",          // out of range
        "\"flag\":true,\"stranger\":1",        // unknown key
        "\"flag\":1",                          // wrong type
        "\"mode\":\"c\"",                      // not a choice
        "\"names\":[\"a\",2]",                 // mixed list
        "\"names\":{\"a\":1}",                 // object
        "\"archivePassword\":\"hunter2\"",     // a secret
        "\"flag\":null",                       // null
    ])
    func oneBadSettingRefusesTheWholeFile(_ settings: String) throws {
        #expect(throws: PreferencesTransferError.self) { try PreferencesFile.decode(file(settings), schema: try schema()) }
    }

    @Test func aSecretIsNamedAsTheReason() throws {
        do {
            _ = try PreferencesFile.decode(file("\"flag\":true,\"zipPassword\":\"x\""), schema: try schema())
            Issue.record("a secret was imported")
        } catch let error as PreferencesTransferError {
            #expect(error.localizedDescription.contains("secret"))
            #expect(!error.localizedDescription.contains("\"x\""))
        }
    }

    @Test func otherFilesAreRefused() throws {
        let s = try schema()
        #expect(throws: PreferencesTransferError.self) { try PreferencesFile.decode(Data("not json".utf8), schema: s) }
        #expect(throws: PreferencesTransferError.self) { try PreferencesFile.decode(Data("[]".utf8), schema: s) }
        #expect(throws: PreferencesTransferError.self) { try PreferencesFile.decode(file("", format: "other"), schema: s) }
        #expect(throws: PreferencesTransferError.self) { try PreferencesFile.decode(file("", version: 2), schema: s) }
        #expect(throws: PreferencesTransferError.self) { try PreferencesFile.decode(file("", version: 0), schema: s) }
        #expect(throws: PreferencesTransferError.self) {
            try PreferencesFile.decode(Data(count: PreferencesFile.maxBytes + 1), schema: s)
        }
    }

    @Test func readAndWriteGoThroughTheDisk() throws {
        let dir = try FaultFixture.tempDir("hspace-prefs")
        defer { FaultFixture.remove(dir) }
        let url = dir.appendingPathComponent("prefs.json")
        let (data, _) = try PreferencesFile.encode(["flag": .bool(true)], schema: try schema(), appVersion: "1")
        try PreferencesFile.write(data, to: url)
        #expect(try PreferencesFile.read(from: url, schema: try schema()).values == ["flag": .bool(true)])
    }

    @Test func aMissingOrUnreadableFileIsReported() async throws {
        let dir = try FaultFixture.tempDir("hspace-prefs")
        defer { FaultFixture.remove(dir) }
        #expect(throws: PreferencesTransferError.self) {
            try PreferencesFile.read(from: dir.appendingPathComponent("none.json"), schema: try schema())
        }
        let url = dir.appendingPathComponent("prefs.json")
        try FaultFixture.write(file("\"flag\":true"), to: url)
        try await FaultFixture.withUnreadable(url) {
            #expect(throws: PreferencesTransferError.self) { try PreferencesFile.read(from: url, schema: try schema()) }
        }
    }

    @Test func aFailedWriteKeepsTheOldFile() async throws {
        let dir = try FaultFixture.tempDir("hspace-prefs")
        defer { FaultFixture.remove(dir) }
        let url = dir.appendingPathComponent("prefs.json")
        try FaultFixture.write(Data("old".utf8), to: url)
        try await FaultFixture.withReadOnly(dir) {
            #expect(throws: PreferencesTransferError.self) { try PreferencesFile.write(Data("new".utf8), to: url) }
        }
        #expect(try Data(contentsOf: url) == Data("old".utf8))
    }
}
