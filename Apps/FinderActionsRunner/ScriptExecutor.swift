import Foundation
import FinderActionsCore
import UserNotifications

struct ExecutionRequest: Sendable {
    let selectedPaths: [String]
    let targetDirectory: String
}

final class ScriptExecutor: @unchecked Sendable {
    private let logStore: RunLogStore
    private let workQueue = DispatchQueue(label: "FinderActions.Executor", attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 4)

    init(logStore: RunLogStore) {
        self.logStore = logStore
    }

    @discardableResult
    func enqueue(action: FinderAction, request: ExecutionRequest) -> UUID {
        let id = UUID()
        let initial = RunRecord(
            id: id,
            actionID: action.id,
            actionName: action.name,
            selectedPaths: request.selectedPaths,
            targetDirectory: request.targetDirectory
        )
        try? logStore.save(initial)

        workQueue.async { [self] in
            slots.wait()
            defer { slots.signal() }
            execute(action: action, request: request, initial: initial)
        }
        return id
    }

    private func execute(action: FinderAction, request: ExecutionRequest, initial: RunRecord) {
        var record = initial
        let stdout = CappedDataBuffer(limit: logStore.limits.maximumStreamBytes)
        let stderr = CappedDataBuffer(limit: logStore.limits.maximumStreamBytes)
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdout.append(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderr.append(data) }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", action.command, action.id] + request.selectedPaths
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if FileManager.default.fileExists(atPath: request.targetDirectory) {
            process.currentDirectoryURL = URL(fileURLWithPath: request.targetDirectory, isDirectory: true)
        }
        process.environment = executionEnvironment(action: action, request: request)

        do {
            try process.run()
            process.waitUntilExit()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            stdout.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            stderr.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

            record.endedAt = Date()
            record.exitCode = process.terminationStatus
            switch process.terminationReason {
            case .exit:
                record.status = process.terminationStatus == 0 ? .succeeded : .failed
                record.terminationReason = "exit"
            case .uncaughtSignal:
                record.status = .signaled
                record.terminationReason = "signal"
            @unknown default:
                record.status = .failed
                record.terminationReason = "unknown"
            }
        } catch {
            record.endedAt = Date()
            record.status = .failed
            record.terminationReason = "launch"
            stderr.append(Data(error.localizedDescription.utf8))
        }

        record.standardOutput = stdout.string
        record.standardError = stderr.string
        try? logStore.save(record)
        if record.status != .succeeded {
            notifyFailure(record)
        }
    }

    private func executionEnvironment(action: FinderAction, request: ExecutionRequest) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["SHELL"] = "/bin/zsh"
        environment["FINDER_ACTION_ID"] = action.id
        environment["FINDER_ACTION_NAME"] = action.name
        environment["FINDER_ACTION_DIRECTORY"] = request.targetDirectory
        environment["FINDER_ACTION_CONFIG"] = action.configPath
        environment["FINDER_ACTION_CONFIG_DIR"] = URL(fileURLWithPath: action.configPath).deletingLastPathComponent().path
        environment["FINDER_ACTION_SELECTION_COUNT"] = String(request.selectedPaths.count)
        return environment
    }

    private func notifyFailure(_ record: RunRecord) {
        let content = UNMutableNotificationContent()
        content.title = "Finder action failed"
        if let exitCode = record.exitCode {
            content.body = "\(record.actionName) exited with status \(exitCode)."
        } else {
            content.body = "\(record.actionName) could not be completed."
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: record.id.uuidString,
            content: content,
            trigger: nil
        ))
    }
}

private final class CappedDataBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if incoming.count > remaining { truncated = true }
        if remaining > 0 { data.append(incoming.prefix(remaining)) }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        var result = String(decoding: data, as: UTF8.self)
        if truncated { result += "\n[output truncated]\n" }
        return result
    }
}
