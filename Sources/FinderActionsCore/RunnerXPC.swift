import Foundation

@objc(FARunnerXPCProtocol)
public protocol RunnerXPCProtocol {
    func run(_ request: RunRequest, withReply reply: @escaping (RunReply) -> Void)
    func reload(withReply reply: @escaping (RunReply) -> Void)
    func ping(withReply reply: @escaping (RunReply) -> Void)
    func notificationStatus(withReply reply: @escaping (String) -> Void)
    func requestNotificationAuthorization(withReply reply: @escaping (RunReply) -> Void)
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

    public var errorDescription: String? {
        switch self {
        case .connectionInterrupted:
            "The Finder Actions runner connection was interrupted."
        case .connectionInvalidated:
            "The Finder Actions runner is unavailable. Enable the background runner and try again."
        case .proxyUnavailable:
            "The Finder Actions runner could not create an XPC proxy."
        }
    }
}

/// Owns the callback-based NSXPCConnection boundary and exposes actor-safe async calls.
public final class RunnerClient: @unchecked Sendable {
    private let machServiceName: String

    public init(machServiceName: String) {
        self.machServiceName = machServiceName
    }

    public func run(_ request: RunRequest) async throws -> RunReply {
        try await call { proxy, reply in
            proxy.run(request, withReply: reply)
        }
    }

    public func reload() async throws -> RunReply {
        try await call { proxy, reply in
            proxy.reload(withReply: reply)
        }
    }

    public func ping() async throws -> RunReply {
        try await call { proxy, reply in
            proxy.ping(withReply: reply)
        }
    }

    public func notificationStatus() async throws -> String {
        try await call { proxy, reply in
            proxy.notificationStatus(withReply: reply)
        }
    }

    public func requestNotificationAuthorization() async throws -> RunReply {
        try await call { proxy, reply in
            proxy.requestNotificationAuthorization(withReply: reply)
        }
    }

    private func call<Value: Sendable>(
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

final class PendingXPCCall<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var connection: NSXPCConnection?

    init(continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func install(_ connection: NSXPCConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
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
        lock.unlock()

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

    public static func appGroupIdentifier(bundle: Bundle = .main) -> String? {
        infoValue("AppGroupIdentifier", bundle: bundle)
    }

    public static func machServiceName(bundle: Bundle = .main) -> String? {
        infoValue("MachServiceName", bundle: bundle)
    }

    public static func sharedContainerURL(bundle: Bundle = .main) -> URL? {
        guard let identifier = appGroupIdentifier(bundle: bundle) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
