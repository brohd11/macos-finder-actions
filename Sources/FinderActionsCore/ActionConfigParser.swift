import Foundation

public struct ParsedActionFile: Sendable {
    public let action: FinderAction?
    public let diagnostics: [ActionDiagnostic]
}

public struct ActionConfigParser: Sendable {
    private static let knownKeys: Set<String> = [
        "Name", "Exec", "Selection", "Extensions", "Group", "Order",
        "SeparatorBefore", "Icon", "Active",
    ]

    public init() {}

    public func parse(contents: String, fileURL: URL, id: String) -> ParsedActionFile {
        let file = fileURL.path
        var diagnostics: [ActionDiagnostic] = []
        var values: [String: (value: String, line: Int)] = [:]
        var sawSection = false

        for (offset, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }

            if trimmed.hasPrefix("[") {
                if trimmed == "[Finder Action]" && !sawSection {
                    sawSection = true
                } else {
                    diagnostics.append(.init(
                        severity: .error,
                        file: file,
                        line: lineNumber,
                        message: "Expected one [Finder Action] section."
                    ))
                }
                continue
            }

            guard sawSection else {
                diagnostics.append(.init(
                    severity: .error,
                    file: file,
                    line: lineNumber,
                    message: "Properties must follow [Finder Action]."
                ))
                continue
            }

            guard let equals = rawLine.firstIndex(of: "=") else {
                diagnostics.append(.init(
                    severity: .error,
                    file: file,
                    line: lineNumber,
                    message: "Expected Key=Value."
                ))
                continue
            }

            let key = String(rawLine[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(rawLine[rawLine.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)

            guard Self.knownKeys.contains(key) else {
                diagnostics.append(.init(
                    severity: .error,
                    file: file,
                    line: lineNumber,
                    message: "Unknown property \(key)."
                ))
                continue
            }
            if let previous = values[key] {
                diagnostics.append(.init(
                    severity: .error,
                    file: file,
                    line: lineNumber,
                    message: "Duplicate property \(key) (first declared on line \(previous.line))."
                ))
            } else {
                values[key] = (value, lineNumber)
            }
        }

        if !sawSection {
            diagnostics.append(.init(severity: .error, file: file, message: "Missing [Finder Action] section."))
        }

        let name = required("Name", values: values, file: file, diagnostics: &diagnostics)
        let command = required("Exec", values: values, file: file, diagnostics: &diagnostics)

        let selection: SelectionRule
        if let entry = values["Selection"] {
            if let parsed = SelectionRule(configurationValue: entry.value) {
                selection = parsed
            } else {
                selection = .notNone
                diagnostics.append(.init(
                    severity: .error,
                    file: file,
                    line: entry.line,
                    message: "Selection must be none, single, multiple, notnone, any, or a nonnegative integer."
                ))
            }
        } else {
            selection = .notNone
        }

        let extensions = parseExtensions(values["Extensions"], file: file, diagnostics: &diagnostics)
        let group = parseGroup(values["Group"], file: file, diagnostics: &diagnostics)
        let order = parseInteger("Order", defaultValue: 1_000, values: values, file: file, diagnostics: &diagnostics)
        let separatorBefore = parseBoolean("SeparatorBefore", defaultValue: false, values: values, file: file, diagnostics: &diagnostics)
        let isActive = parseBoolean("Active", defaultValue: true, values: values, file: file, diagnostics: &diagnostics)
        let icon = values["Icon"]?.value.nilIfEmpty

        guard !diagnostics.contains(where: { $0.severity == .error }), let name, let command else {
            return ParsedActionFile(action: nil, diagnostics: diagnostics)
        }

        return ParsedActionFile(
            action: FinderAction(
                id: id,
                name: name,
                command: command,
                selection: selection,
                extensions: extensions,
                group: group,
                order: order,
                separatorBefore: separatorBefore,
                icon: icon,
                isActive: isActive,
                configPath: file
            ),
            diagnostics: diagnostics
        )
    }

    private func required(
        _ key: String,
        values: [String: (value: String, line: Int)],
        file: String,
        diagnostics: inout [ActionDiagnostic]
    ) -> String? {
        guard let entry = values[key], !entry.value.isEmpty else {
            diagnostics.append(.init(severity: .error, file: file, message: "Missing required property \(key)."))
            return nil
        }
        return entry.value
    }

    private func parseExtensions(
        _ entry: (value: String, line: Int)?,
        file: String,
        diagnostics: inout [ActionDiagnostic]
    ) -> ExtensionRule {
        guard let entry else { return .any }
        let parts = entry.value
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        if parts.isEmpty {
            diagnostics.append(.init(severity: .error, file: file, line: entry.line, message: "Extensions cannot be empty."))
            return .any
        }
        if parts.contains("any") && parts.count > 1 {
            diagnostics.append(.init(severity: .error, file: file, line: entry.line, message: "any cannot be combined with other extension rules."))
        }
        if parts.contains("nodirs") && parts.count > 1 {
            diagnostics.append(.init(severity: .error, file: file, line: entry.line, message: "nodirs cannot be combined with other extension rules."))
        }
        for part in parts where part != "any" && part != "nodirs" && part != "dir" && part != "none" {
            if part.hasPrefix(".") || part.contains("/") || part.contains(" ") {
                diagnostics.append(.init(
                    severity: .error,
                    file: file,
                    line: entry.line,
                    message: "Extension '\(part)' must not contain a dot, slash, or space."
                ))
            }
        }
        return ExtensionRule(values: Array(Set(parts)).sorted())
    }

    private func parseGroup(
        _ entry: (value: String, line: Int)?,
        file: String,
        diagnostics: inout [ActionDiagnostic]
    ) -> [String] {
        guard let entry, !entry.value.isEmpty else { return [] }
        let components = entry.value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            diagnostics.append(.init(severity: .error, file: file, line: entry.line, message: "Group contains an empty path component."))
            return []
        }
        return components.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func parseInteger(
        _ key: String,
        defaultValue: Int,
        values: [String: (value: String, line: Int)],
        file: String,
        diagnostics: inout [ActionDiagnostic]
    ) -> Int {
        guard let entry = values[key] else { return defaultValue }
        guard let parsed = Int(entry.value) else {
            diagnostics.append(.init(severity: .error, file: file, line: entry.line, message: "\(key) must be an integer."))
            return defaultValue
        }
        return parsed
    }

    private func parseBoolean(
        _ key: String,
        defaultValue: Bool,
        values: [String: (value: String, line: Int)],
        file: String,
        diagnostics: inout [ActionDiagnostic]
    ) -> Bool {
        guard let entry = values[key] else { return defaultValue }
        switch entry.value.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default:
            diagnostics.append(.init(severity: .error, file: file, line: entry.line, message: "\(key) must be true or false."))
            return defaultValue
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
