import Foundation
import HSpaceContracts

// ArchivePasswords pod's sole public contract surface (Axiom 3):
// the list of passwords to try on encrypted archives. It lives in the Keychain and nowhere else: one item holding the whole
// list, so that one approval covers it. Nothing here writes a password to a file or a log, and a saved password prints as its label.

public struct PasswordListError: ClassifiedError {
    public let errorClass: ErrorClass
    public let localizedDescription: String
    public let path: String? = nil

    init(_ cls: ErrorClass, _ message: String) {
        self.errorClass = cls
        self.localizedDescription = message
    }
}

public struct SavedPassword: Codable, Sendable, Hashable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let label: String
    public let password: String

    public init(id: UUID = UUID(), label: String, password: String) {
        self.id = id
        self.label = label
        self.password = password
    }

    public var description: String { label }
    public var debugDescription: String { label }
}

/// Where the list is kept. The Keychain in the app, memory in tests.
public protocol SecretStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

/// A generic password item in the login Keychain
public struct KeychainSecretStore: SecretStore {
    let service: String
    let account: String

    public init(service: String = "com.hoax017.hspace.archive-passwords", account: String = "saved-passwords") {
        self.service = service
        self.account = account
    }

    public func read() throws -> Data? { try readItem() }
    public func write(_ data: Data) throws { try writeItem(data) }
    public func delete() throws { try deleteItem() }
}

/// Every call reads the store, so there is no copy to go stale and no password held longer than needed.
public struct PasswordList: Sendable {
    private let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
    }

    /// Throws if the item cannot be read or decoded. It never treats a damaged item as empty, because `add` would then overwrite it.
    public func load() throws -> [SavedPassword] {
        guard let data = try store.read() else { return [] }
        do {
            return try JSONDecoder().decode([SavedPassword].self, from: data)
        } catch {
            throw PasswordListError(.external, "The saved archive passwords could not be read")     // No detail: it could quote the data
        }
    }

    /// A password already on the list is not added twice.
    @discardableResult
    public func add(label: String, password: String) throws -> SavedPassword {
        guard !password.isEmpty else { throw PasswordListError(.logic, "A password cannot be empty") }
        var list = try load()
        if let existing = list.first(where: { $0.password == password }) { return existing }
        let entry = SavedPassword(label: label, password: password)
        list.append(entry)
        try save(list)
        return entry
    }

    public func remove(id: SavedPassword.ID) throws {
        let list = try load()
        let kept = list.filter { $0.id != id }
        guard kept.count != list.count else { return }
        try save(kept)
    }

    private func save(_ list: [SavedPassword]) throws {
        guard !list.isEmpty else {
            try store.delete()
            return
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(list)
        } catch {
            throw PasswordListError(.logic, "The archive passwords could not be encoded")
        }
        try store.write(data)
    }
}
