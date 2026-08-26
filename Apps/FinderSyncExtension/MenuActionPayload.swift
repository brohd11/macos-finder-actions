import Foundation
import FinderActionsCore

struct MenuActionPayload: Equatable, Sendable {
    let actionID: String
    let selectedPaths: [String]
    let targetDirectory: String
    let invocationKind: InvocationKind

    init(actionID: String, invocation: FinderInvocation) {
        self.actionID = actionID
        self.selectedPaths = invocation.items.map(\.path)
        self.targetDirectory = invocation.targetDirectory
        self.invocationKind = invocation.kind
    }

    var runRequest: RunRequest {
        RunRequest(
            actionID: actionID,
            selectedPaths: selectedPaths,
            targetDirectory: targetDirectory,
            invocationKind: invocationKind
        )
    }

}

final class MenuActionRegistry: @unchecked Sendable {
    static let shared = MenuActionRegistry()

    private let maximumEntries: Int
    private let lock = NSLock()
    private var nextTag = 1
    private var payloads: [Int: MenuActionPayload] = [:]
    private var insertionOrder: [Int] = []

    init(maximumEntries: Int = 2_048) {
        self.maximumEntries = max(1, maximumEntries)
    }

    func register(_ payload: MenuActionPayload) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let tag = nextAvailableTag()
        payloads[tag] = payload
        insertionOrder.append(tag)

        while insertionOrder.count > maximumEntries {
            payloads.removeValue(forKey: insertionOrder.removeFirst())
        }
        return tag
    }

    func take(tag: Int) -> MenuActionPayload? {
        lock.lock()
        defer { lock.unlock() }
        guard let payload = payloads.removeValue(forKey: tag) else { return nil }
        insertionOrder.removeAll { $0 == tag }
        return payload
    }

    private func nextAvailableTag() -> Int {
        while payloads[nextTag] != nil {
            nextTag = nextTag == Int.max ? 1 : nextTag + 1
        }
        let tag = nextTag
        nextTag = nextTag == Int.max ? 1 : nextTag + 1
        return tag
    }
}
