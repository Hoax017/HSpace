import ArchivePasswords
import Foundation
import HSpaceContracts
import HSpaceTestSupport
import Testing

private final class MemoryStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var failure: PasswordListError?

    init(data: Data? = nil) {
        self.data = data
    }

    var stored: Data? { lock.withLock { data } }

    func failWith(_ error: PasswordListError) {
        lock.withLock { failure = error }
    }

    func read() throws -> Data? {
        try lock.withLock {
            if let failure { throw failure }
            return data
        }
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            if let failure { throw failure }
            self.data = data
        }
    }

    func delete() throws {
        try lock.withLock {
            if let failure { throw failure }
            data = nil
        }
    }
}

@Suite struct PasswordListTests {
    @Test func anEmptyStoreIsAnEmptyList() throws {
        #expect(try PasswordList(store: MemoryStore()).load().isEmpty)
    }

    @Test func addedPasswordsComeBackInOrder() throws {
        let list = PasswordList(store: MemoryStore())
        try list.add(label: "Work", password: "one")
        try list.add(label: "Home", password: "two")
        #expect(try list.load().map(\.label) == ["Work", "Home"])
        #expect(try list.load().map(\.password) == ["one", "two"])
    }

    @Test func aPasswordIsListedOnce() throws {
        let list = PasswordList(store: MemoryStore())
        let first = try list.add(label: "Work", password: "same")
        let second = try list.add(label: "Other", password: "same")
        #expect(first == second)
        #expect(try list.load().count == 1)
    }

    @Test func anEmptyPasswordIsRefused() {
        #expect(throws: PasswordListError.self) {
            try PasswordList(store: MemoryStore()).add(label: "Empty", password: "")
        }
    }

    @Test func removingTheLastPasswordRemovesTheItem() throws {
        let store = MemoryStore()
        let list = PasswordList(store: store)
        let entry = try list.add(label: "Work", password: "one")
        try list.remove(id: UUID())     // Unknown: nothing happens
        #expect(try list.load().count == 1)

        try list.remove(id: entry.id)

        #expect(store.stored == nil)
    }

    /// add() must never replace something it could not read
    @Test func aDamagedItemIsAnErrorAndStaysUntouched() throws {
        let damaged = Data("not json".utf8)
        let store = MemoryStore(data: damaged)
        let list = PasswordList(store: store)

        #expect(throws: PasswordListError.self) { try list.load() }
        #expect(throws: PasswordListError.self) { try list.add(label: "New", password: "pw") }
        #expect(store.stored == damaged)
    }

    @Test func aStoreFailureReachesTheCaller() throws {
        let store = MemoryStore()
        let list = PasswordList(store: store)
        try list.add(label: "Work", password: "one")
        store.failWith(PasswordListErrorFixture.make())

        #expect(throws: (any Error).self) { try list.load() }
        #expect(throws: (any Error).self) { try list.add(label: "New", password: "pw") }
    }

    @Test func aSavedPasswordNeverPrintsItsSecret() {
        let entry = SavedPassword(label: "Work", password: "hunter2")
        #expect(!"\(entry)".contains("hunter2"))
        #expect(!String(describing: entry).contains("hunter2"))
        #expect(!String(reflecting: entry).contains("hunter2"))
        #expect(!"\([entry])".contains("hunter2"))
    }

    /// Off by default: it touches the login Keychain, and could raise a system prompt.
    /// To run it: HSPACE_TEST_KEYCHAIN=1 ./scripts/test.sh --filter theRealKeychainRoundTrips
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HSPACE_TEST_KEYCHAIN"] != nil))
    func theRealKeychainRoundTrips() throws {
        let store = KeychainSecretStore(service: "com.hoax017.hspace.test-\(UUID().uuidString)")
        defer { try? store.delete() }   // Test item
        let list = PasswordList(store: store)

        #expect(try list.load().isEmpty)
        let entry = try list.add(label: "Test", password: "test value")
        try list.add(label: "Second", password: "another")
        #expect(try list.load().map(\.password) == ["test value", "another"])
        try list.remove(id: entry.id)
        #expect(try list.load().map(\.label) == ["Second"])
        try store.delete()
        #expect(try store.read() == nil)
        try store.delete()      // Already gone is fine
    }
}

private enum PasswordListErrorFixture {
    /// The error type has no public initializer, and an empty password is the public way to get one
    static func make() -> PasswordListError {
        do {
            try PasswordList(store: MemoryStore()).add(label: "", password: "")
        } catch let error as PasswordListError {
            return error
        } catch {}
        fatalError("add must refuse an empty password")
    }
}
