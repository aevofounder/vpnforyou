import Foundation

/// Storage for secrets: the macOS Keychain in the app, memory in tests.
public protocol SecretStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func data(for key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[key]
    }

    public func set(_ data: Data, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[key] = data
    }

    public func remove(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[key] = nil
    }
}
