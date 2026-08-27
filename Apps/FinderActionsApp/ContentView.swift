import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            setupBar
                .padding()
            Divider()
            TabView {
                actionsView
                    .tabItem { Label("Actions", systemImage: "list.bullet.rectangle") }
                diagnosticsView
                    .tabItem { Label("Problems", systemImage: "exclamationmark.triangle") }
                runsView
                    .tabItem { Label("Runs", systemImage: "terminal") }
            }
            .padding([.horizontal, .bottom])
        }
        .alert("Finder Actions", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    private var setupBar: some View {
        HStack(spacing: 12) {
            statusCard(
                title: "Finder extension",
                value: state.extensionEnabled ? "Enabled" : "Disabled",
                positive: state.extensionEnabled,
                button: "Manage",
                action: state.manageFinderExtension
            )
            statusCard(
                title: "Background runner",
                value: state.runnerStatus,
                positive: state.runnerAvailable,
                button: state.runnerControlTitle,
                action: state.controlRunner,
                buttonDisabled: state.runnerControlDisabled
            )
            statusCard(
                title: "Failure notifications",
                value: state.notificationStatus,
                positive: state.notificationStatus == "Enabled",
                button: "Allow",
                action: state.requestNotifications,
                buttonDisabled: !state.runnerAvailable || state.notificationAuthorizationInFlight
            )
        }
    }

    private func statusCard(
        title: String,
        value: String,
        positive: Bool,
        button: String,
        action: @escaping () -> Void,
        buttonDisabled: Bool = false
    ) -> some View {
        GroupBox {
            HStack {
                Image(systemName: positive ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(positive ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).fontWeight(.medium)
                }
                Spacer()
                Button(button, action: action)
                    .disabled(buttonDisabled)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var actionsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(state.snapshot?.actions.count ?? 0) active actions")
                    .font(.headline)
                Spacer()
                Button("Copy Example", action: state.copyExample)
                Button("Choose…", action: state.chooseConfigDirectory)
                Button("Reset", action: state.resetConfigDirectory)
                    .disabled(!state.usesCustomConfigDirectory)
                Button("Reveal", action: state.revealConfigFolder)
                Button("Reload Now", action: state.reloadConfiguration)
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.runnerAvailable)
            }
            Text(state.configRoot.path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            List(state.snapshot?.actions ?? []) { action in
                HStack {
                    if let icon = action.icon { Image(systemName: icon) }
                    VStack(alignment: .leading) {
                        Text(action.name)
                        Text(action.group.isEmpty ? "Top level" : action.group.joined(separator: " › "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(action.selection.configurationValue)
                        .font(.system(.caption, design: .monospaced))
                    Text(action.extensions.values.joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 120, alignment: .trailing)
                }
                .help(action.configPath)
            }
            .overlay {
                if state.snapshot?.actions.isEmpty != false {
                    Text("Add a .finder-action file to the config folder.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Configuration diagnostics").font(.headline)
            List(state.snapshot?.diagnostics ?? []) { diagnostic in
                HStack(alignment: .top) {
                    Image(systemName: diagnostic.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                    VStack(alignment: .leading) {
                        Text(diagnostic.message)
                        Text("\(diagnostic.file)\(diagnostic.line.map { ":\($0)" } ?? "")")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .overlay {
                if state.snapshot?.diagnostics.isEmpty != false {
                    Text("No configuration problems.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var runsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent runs").font(.headline)
                Spacer()
                Button("Clear Logs", action: state.clearLogs)
                    .disabled(state.runs.isEmpty)
            }
            HSplitView {
                List(state.runs, selection: $state.selectedRunID) { run in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(run.actionName).fontWeight(.medium)
                            Spacer()
                            Text(run.status.rawValue)
                                .foregroundStyle(run.status == .succeeded ? .green : run.status == .running ? .secondary : .red)
                        }
                        Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(run.id)
                }
                .frame(minWidth: 250)

                runDetails
                    .frame(minWidth: 360)
            }
        }
    }

    @ViewBuilder
    private var runDetails: some View {
        if let run = state.selectedRun {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(run.actionName).font(.title2)
                    Text("Exit: \(run.exitCode.map(String.init) ?? "—") · \(run.status.rawValue)")
                        .foregroundStyle(.secondary)
                    if !run.selectedPaths.isEmpty {
                        detailSection("Selection", text: run.selectedPaths.joined(separator: "\n"))
                    }
                    detailSection("Standard output", text: run.standardOutput.isEmpty ? "(empty)" : run.standardOutput)
                    detailSection("Standard error", text: run.standardError.isEmpty ? "(empty)" : run.standardError)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            Text("Select a run to inspect its output.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
