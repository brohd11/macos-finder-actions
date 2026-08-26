import Foundation
import FinderActionsCore

enum SelfTestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): message }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SelfTestFailure.failed(message) }
}

func fixtureAction(
    id: String,
    name: String,
    selection: SelectionRule = .notNone,
    extensions: [String] = ["any"],
    group: [String] = [],
    order: Int = 1_000
) -> FinderAction {
    FinderAction(
        id: id,
        name: name,
        command: "true",
        selection: selection,
        extensions: ExtensionRule(values: extensions),
        group: group,
        order: order,
        configPath: "/tmp/\(id).finder-action"
    )
}

do {
    let source = """
    [Finder Action]
    Name=Resize Images
    Exec="$FINDER_ACTION_CONFIG_DIR/resize.sh" "$@"
    Selection=multiple
    Extensions=jpg;PNG;
    Group=Images/Resize
    Order=20
    SeparatorBefore=true
    """
    let parsed = ActionConfigParser().parse(
        contents: source,
        fileURL: URL(fileURLWithPath: "/tmp/resize.finder-action"),
        id: "resize.finder-action"
    )
    let action = try parsed.action.unwrap("Valid action did not parse: \(parsed.diagnostics)")
    try expect(action.extensions.values == ["jpg", "png"], "Extensions were not normalized")
    try expect(action.group == ["Images", "Resize"], "Group was not parsed")

    let broken = ActionConfigParser().parse(
        contents: "[Finder Action]\nName=Bad\nExec=true\nUnknown=x",
        fileURL: URL(fileURLWithPath: "/tmp/bad.finder-action"),
        id: "bad.finder-action"
    )
    try expect(broken.action == nil, "Unknown keys must invalidate actions")

    let png = FinderItem(path: "/tmp/a.PNG", isDirectory: false)
    let jpg = FinderItem(path: "/tmp/b.jpg", isDirectory: false)
    let invocation = FinderInvocation(kind: .items, items: [png, jpg], targetDirectory: "/tmp")
    try expect(ActionMatcher.matches(action, invocation: invocation), "Multi-extension selection did not match")

    let entries = ActionMenuBuilder.build(actions: [
        fixtureAction(id: "copy", name: "Copy", order: 30),
        fixtureAction(id: "png", name: "PNG", group: ["Images", "Convert"], order: 20),
        fixtureAction(id: "resize", name: "Resize", group: ["Images"], order: 10),
    ])
    try expect(entries.map(\.label) == ["Images", "Copy"], "Menu ordering was incorrect")

    let unusualPaths = ["/tmp/with space", "/tmp/with'quote", "/tmp/with\nnewline", "/tmp/ユニコード"]
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", "printf '%s\\0' \"$@\"", "self-test"] + unusualPaths
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    let roundTrippedPaths = bytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    try expect(roundTrippedPaths == unusualPaths, "Shell positional arguments were not preserved")

    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let logs = RunLogStore(directory: temporary, limits: .init(maximumRecords: 2, maximumAge: 10_000, maximumBytes: 1_000_000))
    for index in 0..<3 {
        try logs.save(RunRecord(
            actionID: "action-\(index)",
            actionName: "Action \(index)",
            selectedPaths: [],
            targetDirectory: "/tmp",
            startedAt: Date().addingTimeInterval(Double(index))
        ))
        Thread.sleep(forTimeInterval: 0.01)
    }
    try expect(logs.loadAll().count == 2, "Run log pruning failed")
    print("Finder Actions self-test passed")
} catch {
    FileHandle.standardError.write(Data("Finder Actions self-test failed: \(error)\n".utf8))
    exit(1)
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw SelfTestFailure.failed(message) }
        return self
    }
}
