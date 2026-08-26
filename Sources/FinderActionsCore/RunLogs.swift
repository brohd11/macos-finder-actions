import Foundation

public enum RunStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case signaled
    case rejected
}

public struct RunRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let actionID: String
    public let actionName: String
    public let selectedPaths: [String]
    public let targetDirectory: String
    public let startedAt: Date
    public var endedAt: Date?
    public var status: RunStatus
    public var exitCode: Int32?
    public var terminationReason: String?
    public var standardOutput: String
    public var standardError: String

    public init(
        id: UUID = UUID(),
        actionID: String,
        actionName: String,
        selectedPaths: [String],
        targetDirectory: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: RunStatus = .running,
        exitCode: Int32? = nil,
        terminationReason: String? = nil,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.id = id
        self.actionID = actionID
        self.actionName = actionName
        self.selectedPaths = selectedPaths
        self.targetDirectory = targetDirectory
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.exitCode = exitCode
        self.terminationReason = terminationReason
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public final class RunLogStore: @unchecked Sendable {
    public struct Limits: Sendable {
        public let maximumRecords: Int
        public let maximumAge: TimeInterval
        public let maximumBytes: Int
        public let maximumStreamBytes: Int

        public init(
            maximumRecords: Int = 200,
            maximumAge: TimeInterval = 30 * 24 * 60 * 60,
            maximumBytes: Int = 50 * 1_024 * 1_024,
            maximumStreamBytes: Int = 1_024 * 1_024
        ) {
            self.maximumRecords = maximumRecords
            self.maximumAge = maximumAge
            self.maximumBytes = maximumBytes
            self.maximumStreamBytes = maximumStreamBytes
        }
    }

    public let directory: URL
    public let limits: Limits
    private let queue = DispatchQueue(label: "FinderActions.RunLogStore")

    public init(directory: URL, limits: Limits = Limits()) {
        self.directory = directory
        self.limits = limits
    }

    public func save(_ record: RunRecord) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            try data.write(to: fileURL(for: record.id), options: .atomic)
            try pruneLocked(now: Date())
        }
    }

    @discardableResult
    public func saveRejected(
        actionID: String,
        actionName: String,
        selectedPaths: [String],
        targetDirectory: String,
        message: String,
        at date: Date = Date()
    ) throws -> RunRecord {
        let record = RunRecord(
            actionID: actionID,
            actionName: actionName,
            selectedPaths: selectedPaths,
            targetDirectory: targetDirectory,
            startedAt: date,
            endedAt: date,
            status: .rejected,
            terminationReason: "rejected",
            standardError: message
        )
        try save(record)
        return record
    }

    public func loadAll() -> [RunRecord] {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return files.compactMap { url in
                guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(RunRecord.self, from: data)
            }.sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func clear() throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func pruneLocked(now: Date) throws {
        struct FileInfo {
            let url: URL
            let modified: Date
            let size: Int
        }

        var files: [FileInfo] = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return FileInfo(url: url, modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
        }.sorted { $0.modified > $1.modified }

        let cutoff = now.addingTimeInterval(-limits.maximumAge)
        for file in files where file.modified < cutoff {
            try? FileManager.default.removeItem(at: file.url)
        }
        files.removeAll { $0.modified < cutoff }

        var bytes = 0
        for (index, file) in files.enumerated() {
            bytes += file.size
            if index >= limits.maximumRecords || bytes > limits.maximumBytes {
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }
}
