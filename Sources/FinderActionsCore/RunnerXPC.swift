import Foundation

@objc(FARunnerXPCProtocol)
public protocol RunnerXPCProtocol {
    func run(_ request: RunRequest, withReply reply: @escaping (RunReply) -> Void)
    func reload(withReply reply: @escaping (RunReply) -> Void)
    func catalogSnapshot(withReply reply: @escaping (CatalogSnapshotReply) -> Void)
    func ping(withReply reply: @escaping (RunReply) -> Void)
    func notificationStatus(withReply reply: @escaping (String) -> Void)
    func requestNotificationAuthorization(withReply reply: @escaping (RunReply) -> Void)
}

@objc(FACatalogSnapshotReply)
public final class CatalogSnapshotReply: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let snapshotData: Data?
    public let message: String

    public init(snapshotData: Data?, message: String = "") {
        self.snapshotData = snapshotData
        self.message = message
    }

    public convenience init(snapshot: ActionSnapshot) throws {
        try self.init(snapshotData: JSONEncoder().encode(snapshot))
    }

    public required init?(coder: NSCoder) {
        snapshotData = coder.decodeObject(of: NSData.self, forKey: "snapshotData") as Data?
        guard let message = coder.decodeObject(of: NSString.self, forKey: "message") as String? else {
            return nil
        }
        self.message = message
    }

    public func encode(with coder: NSCoder) {
        coder.encode(snapshotData as NSData?, forKey: "snapshotData")
        coder.encode(message as NSString, forKey: "message")
    }

    public func decodedSnapshot() throws -> ActionSnapshot {
        guard let snapshotData else {
            throw RunnerClientError.catalogUnavailable(
                message.isEmpty ? "The runner did not provide an action catalog." : message
            )
        }
        do {
            return try JSONDecoder().decode(ActionSnapshot.self, from: snapshotData)
        } catch {
            throw RunnerClientError.invalidCatalog(error.localizedDescription)
        }
    }
}

@objc(FARunRequest)
public final class RunRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let actionID: String
    public let selectedPaths: [String]
    public let targetDirectory: String
    public let invocationKind: String

    public init(actionID: String, selectedPaths: [String], targetDirectory: String, invocationKind: InvocationKind) {
        self.actionID = actionID
        self.selectedPaths = selectedPaths
        self.targetDirectory = targetDirectory
        self.invocationKind = invocationKind.rawValue
    }

    public required init?(coder: NSCoder) {
        guard
            let actionID = coder.decodeObject(of: NSString.self, forKey: "actionID") as String?,
            let selectedPaths = coder.decodeObject(of: [NSArray.self, NSString.self], forKey: "selectedPaths") as? [String],
            let targetDirectory = coder.decodeObject(of: NSString.self, forKey: "targetDirectory") as String?,
            let invocationKind = coder.decodeObject(of: NSString.self, forKey: "invocationKind") as String?
        else { return nil }
        self.actionID = actionID
        self.selectedPaths = selectedPaths
        self.targetDirectory = targetDirectory
        self.invocationKind = invocationKind
    }

    public func encode(with coder: NSCoder) {
        coder.encode(actionID as NSString, forKey: "actionID")
        coder.encode(selectedPaths as NSArray, forKey: "selectedPaths")
        coder.encode(targetDirectory as NSString, forKey: "targetDirectory")
        coder.encode(invocationKind as NSString, forKey: "invocationKind")
    }
}

@objc(FARunReply)
public final class RunReply: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let accepted: Bool
    public let message: String
    public let runID: String?

    public init(accepted: Bool, message: String, runID: String? = nil) {
        self.accepted = accepted
        self.message = message
        self.runID = runID
    }

    public required init?(coder: NSCoder) {
        guard
            let message = coder.decodeObject(of: NSString.self, forKey: "message") as String?
        else { return nil }
        self.accepted = coder.decodeBool(forKey: "accepted")
        self.message = message
        self.runID = coder.decodeObject(of: NSString.self, forKey: "runID") as String?
    }

    public func encode(with coder: NSCoder) {
        coder.encode(accepted, forKey: "accepted")
        coder.encode(message as NSString, forKey: "message")
        coder.encode(runID as NSString?, forKey: "runID")
    }
}

public enum XPCInterfaceFactory {
    public static func runnerInterface() -> NSXPCInterface {
        // The protocol uses concrete NSSecureCoding classes rather than collection
        // element types, so NSXPCInterface can derive its allow-list directly.
        NSXPCInterface(with: RunnerXPCProtocol.self)
    }
}

public enum RunnerClientError: LocalizedError, Sendable {
    case connectionInterrupted
    case connectionInvalidated
    case proxyUnavailable
    case timedOut
    case catalogUnavailable(String)
    case invalidCatalog(String)

    public var errorDescription: String? {
        switch self {
        case .connectionInterrupted:
            "The Finder Actions runner connection was interrupted."
        case .connectionInvalidated:
            "The Finder Actions runner is unavailable. Enable the background runner and try again."
        case .proxyUnavailable:
            "The Finder Actions runner could not create an XPC proxy."
        case .timedOut:
            "The Finder Actions runner did not respond in time."
        case .catalogUnavailable(let message):
            message
        case .invalidCatalog(let message):
            "The Finder Actions runner returned an invalid action catalog: \(message)"
        }
    }
}

/// Owns the callback-based NSXPCConnection boundary and exposes actor-safe async calls.
public final class RunnerClient: @unchecked Sendable {
    private static let standardTimeout: TimeInterval = 5
    private static let authorizationTimeout: TimeInterval = 60
    public static let finderMenuTimeout: TimeInterval = 0.5
    private let machServiceName: String

    public init(machServiceName: String) {
        self.machServiceName = machServiceName
    }

    public func run(_ request: RunRequest) async throws -> RunReply {
        try await call(timeout: Self.standardTimeout) { proxy, reply in
            proxy.run(request, withReply: reply)
        }
    }

    public func reload() async throws -> RunReply {
        try await call(timeout: Self.standardTimeout) { proxy, reply in
            proxy.reload(withReply: reply)
        }
    }

    public func catalogSnapshot() async throws -> ActionSnapshot {
        let reply: CatalogSnapshotReply = try await call(timeout: Self.standardTimeout) { proxy, reply in
            proxy.catalogSnapshot(withReply: reply)
        }
        return try reply.decodedSnapshot()
    }

    public func catalogSnapshotSynchronously(
        timeout: TimeInterval = RunnerClient.finderMenuTimeout
    ) throws -> ActionSnapshot {
        let pending = PendingSynchronousXPCCall<CatalogSnapshotReply>()
        let connection = NSXPCConnection(machServiceName: machServiceName)
        connection.remoteObjectInterface = XPCInterfaceFactory.runnerInterface()
        connection.interruptionHandler = {
            pending.fail(RunnerClientError.connectionInterrupted)
        }
        connection.invalidationHandler = {
            pending.fail(RunnerClientError.connectionInvalidated)
        }
        connection.resume()
        defer { connection.invalidate() }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            pending.fail(error)
        }) as? RunnerXPCProtocol else {
            throw RunnerClientError.proxyUnavailable
        }
        proxy.catalogSnapshot { reply in
            pending.succeed(reply)
        }
        return try pending.wait(timeout: timeout).decodedSnapshot()
    }

    public func ping() async throws -> RunReply {
        try await call(timeout: Self.standardTimeout) { proxy, reply in
            proxy.ping(withReply: reply)
        }
    }

    public func notificationStatus() async throws -> String {
        try await call(timeout: Self.standardTimeout) { proxy, reply in
            proxy.notificationStatus(withReply: reply)
        }
    }

    public func requestNotificationAuthorization() async throws -> RunReply {
        try await call(timeout: Self.authorizationTimeout) { proxy, reply in
            proxy.requestNotificationAuthorization(withReply: reply)
        }
    }

    private func call<Value: Sendable>(
        timeout: TimeInterval,
        _ invoke: @escaping @Sendable (RunnerXPCProtocol, @escaping (Value) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingXPCCall(continuation: continuation)
            let connection = NSXPCConnection(machServiceName: machServiceName)
            connection.remoteObjectInterface = XPCInterfaceFactory.runnerInterface()
            pending.install(connection)
            connection.interruptionHandler = {
                pending.fail(RunnerClientError.connectionInterrupted)
            }
            connection.invalidationHandler = {
                pending.fail(RunnerClientError.connectionInvalidated)
            }
            pending.scheduleTimeout(after: timeout)
            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                pending.fail(error)
            }) as? RunnerXPCProtocol else {
                pending.fail(RunnerClientError.proxyUnavailable)
                return
            }

            invoke(proxy) { value in
                pending.succeed(value)
            }
        }
    }
}

private final class PendingSynchronousXPCCall<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, any Error>?

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: any Error) {
        finish(.failure(error))
    }

    func wait(timeout: TimeInterval) throws -> Value {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            lock.lock()
            if result == nil {
                result = .failure(RunnerClientError.timedOut)
            }
            let result = self.result!
            lock.unlock()
            return try result.get()
        }
        lock.lock()
        let result = self.result!
        lock.unlock()
        return try result.get()
    }

    private func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }
}

final class PendingXPCCall<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var connection: NSXPCConnection?
    private var timeoutWorkItem: DispatchWorkItem?

    init(continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func install(_ connection: NSXPCConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    func scheduleTimeout(after interval: TimeInterval) {
        let item = DispatchWorkItem {
            self.fail(RunnerClientError.timedOut)
        }
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            item.cancel()
            return
        }
        timeoutWorkItem = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: item)
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        let timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        continuation.resume(with: result)
        connection?.invalidate()
    }
}

public enum RuntimeConfiguration {
    public static func infoValue(_ key: String, bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.contains("$(")
        else { return nil }
        return value
    }

    public static func machServiceName(bundle: Bundle = .main) -> String? {
        infoValue("MachServiceName", bundle: bundle)
    }
}
