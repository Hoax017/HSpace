import Foundation
import HSpaceContracts

// PreferencesTransfer pod's sole public contract surface (Axiom 3): writing the owner's settings to a file and reading
// them back. A file is checked whole before anything is returned, so a bad file never applies in part. Only the settings
// the app lists in its schema travel, and nothing that looks like a secret ever does.

public struct PreferencesTransferError: ClassifiedError, LocalizedError, Equatable {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    /// What `localizedDescription` gives on `any Error`, which is how the app receives it
    public var errorDescription: String? { localizedDescription }

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

/// What a setting may hold
public enum PreferenceKind: Sendable, Equatable {
    case bool
    case integer(ClosedRange<Int>)
    case number(ClosedRange<Double>)
    /// One of a fixed set of words
    case choice(Set<String>)
    /// Text that matches a regular expression whole
    case text(pattern: String)
    /// Up to `maxCount` texts, each matching `pattern` whole
    case list(maxCount: Int, pattern: String)
}

/// A setting's value as it travels in the file
public enum PreferenceValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case text(String)
    case list([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .text(value) }
        else if let value = try? container.decode([String].self) { self = .list(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a setting value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        }
    }
}

/// The settings that may travel, and what each may hold
public struct PreferenceSchema: Sendable {
    public let kinds: [String: PreferenceKind]

    /// A key that names a password, token or other secret is refused here, so no schema can ever carry one.
    public init(_ kinds: [String: PreferenceKind]) throws {
        if let secret = kinds.keys.sorted().first(where: Self.looksSecret) {
            throw PreferencesTransferError(.logic, "The setting “\(secret)” looks like a secret, and secrets never go in a preferences file.")
        }
        self.kinds = kinds
    }

    public static func looksSecret(_ key: String) -> Bool {
        let flat = key.lowercased().filter { $0.isLetter }
        return ["password", "passwd", "passphrase", "secret", "token", "credential", "apikey", "privatekey", "keychain"]
            .contains { flat.contains($0) }
    }

    /// The value as the app should store it, or nil when the key is unknown or the value does not fit
    public func validated(_ key: String, _ value: PreferenceValue) -> PreferenceValue? {
        guard let kind = kinds[key] else { return nil }
        switch (kind, value) {
        case (.bool, .bool):
            return value
        case (.integer(let range), .integer(let n)):
            return range.contains(n) ? value : nil
        case (.number(let range), .integer(let n)):
            return range.contains(Double(n)) ? .number(Double(n)) : nil
        case (.number(let range), .number(let x)):
            return x.isFinite && range.contains(x) ? value : nil
        case (.choice(let words), .text(let word)):
            return words.contains(word) ? value : nil
        case (.text(let pattern), .text(let text)):
            return Self.matches(text, pattern) ? value : nil
        case (.list(let maxCount, let pattern), .list(let texts)):
            return texts.count <= maxCount && texts.allSatisfy { Self.matches($0, pattern) } ? value : nil
        default:
            return nil
        }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "\\A(?:\(pattern))\\z", options: [.dotMatchesLineSeparators]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// A preferences file that passed every check
public struct PreferencesDocument: Sendable, Equatable {
    public let values: [String: PreferenceValue]
    /// The HSpace version that wrote it, when it says
    public let appVersion: String?
}

/// The file itself: JSON, with a format name and a version, so another file is never mistaken for one
public enum PreferencesFile {
    public static let format = "hspace-preferences"
    public static let version = 1
    /// Far more than any real set of settings: a larger file is not one
    public static let maxBytes = 1_000_000

    /// Writes only keys the schema knows, with values that fit. The others are returned, so the app can say what stayed out.
    public static func encode(_ values: [String: PreferenceValue], schema: PreferenceSchema,
                              appVersion: String) throws -> (data: Data, left: [String]) {
        var kept: [String: PreferenceValue] = [:]
        var left: [String] = []
        for (key, value) in values {
            if !PreferenceSchema.looksSecret(key), let valid = schema.validated(key, value) { kept[key] = valid } else { left.append(key) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(Envelope(format: format, version: version, app: appVersion, settings: kept))
            return (data, left.sorted())
        } catch {
            throw PreferencesTransferError(.logic, "The settings could not be written out: \(error.localizedDescription)")
        }
    }

    /// Checks the whole file. Any problem refuses all of it, naming the first setting at fault.
    public static func decode(_ data: Data, schema: PreferenceSchema) throws -> PreferencesDocument {
        guard data.count <= maxBytes else { throw refused("it is too large to be a preferences file") }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw refused("it is not an HSpace preferences file, or it is damaged")
        }
        guard envelope.format == format else { throw refused("it is not an HSpace preferences file") }
        guard envelope.version <= version else { throw refused("it was made by a newer version of HSpace") }
        guard envelope.version >= 1 else { throw refused("it is not an HSpace preferences file") }
        var values: [String: PreferenceValue] = [:]
        for key in envelope.settings.keys.sorted() {
            let value = envelope.settings[key]!
            if PreferenceSchema.looksSecret(key) {
                throw refused("it holds “\(key)”, which looks like a secret, and HSpace never imports secrets")
            }
            guard schema.kinds[key] != nil else {
                throw refused("it holds a setting this version does not know: “\(key)”")
            }
            guard let valid = schema.validated(key, value) else {
                throw refused("the setting “\(key)” has a value HSpace cannot use")
            }
            values[key] = valid
        }
        return PreferencesDocument(values: values, appVersion: envelope.app)
    }

    /// Reads at most `maxBytes` plus one, so a huge file is never loaded whole
    public static func read(from url: URL, schema: PreferenceSchema) throws -> PreferencesDocument {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }   // read-only handle: closing cannot lose data
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            throw PreferencesTransferError(.external, "“\(url.lastPathComponent)” could not be read: \(error.localizedDescription)")
        }
        return try decode(data, schema: schema)
    }

    /// Atomic: a failed write leaves any file already there as it was
    public static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw PreferencesTransferError(.external, "“\(url.lastPathComponent)” could not be saved: \(error.localizedDescription)")
        }
    }

    private static func refused(_ why: String) -> PreferencesTransferError {
        PreferencesTransferError(.external, "Nothing was imported, because \(why).")
    }

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let app: String?
        let settings: [String: PreferenceValue]
    }
}
