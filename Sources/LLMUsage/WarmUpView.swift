import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

struct WarmUpView: View {
    @EnvironmentObject private var settings: WarmUpSettings
    @EnvironmentObject private var tracker: TrackerStatus
    @State private var editing: WarmUpSchedule?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    PageHeader("Warm Up")
                    Spacer()
                    if !tracker.isRunning {
                        Text("Tracker stopped")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                schedules
                ForEach(WarmUpClient.allCases) { client in
                    WarmUpClientCard(client: client, configuration: settings.binding(to: client))
                }
                if !settings.state.runs.isEmpty { history }
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .scrollIndicators(.never)
        .sheet(item: $editing) { schedule in
            WarmUpScheduleEditor(schedule: schedule) { settings.save($0) }
        }
        .task {
            while !Task.isCancelled {
                settings.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var schedules: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedules")
                .font(.system(.headline, design: .rounded))
            ForEach(settings.configuration.schedules) { schedule in
                WarmUpScheduleRow(schedule: schedule) { editing = schedule }
            }
            Button("Add schedule") { editing = WarmUpSchedule(clients: [.claude]) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent runs")
                .font(.system(.headline, design: .rounded))
            ForEach(settings.state.runs.prefix(12)) { run in
                WarmUpRunRow(run: run)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct WarmUpScheduleRow: View {
    let schedule: WarmUpSchedule
    let edit: () -> Void
    @EnvironmentObject private var settings: WarmUpSettings

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: settings.binding(to: schedule))
                .toggleStyle(.switch)
                .tint(Brand.active)
                .labelsHidden()
                .accessibilityLabel("\(schedule.timeTitle) \(schedule.weekdaysTitle)")
            Button(action: edit) {
                HStack(spacing: 12) {
                    Text(schedule.timeTitle)
                        .font(.system(.title3, design: .rounded).monospacedDigit())
                        .frame(width: 62, alignment: .leading)
                    Text(schedule.weekdaysTitle)
                        .frame(width: 120, alignment: .leading)
                    Text(schedule.clientsTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                settings.remove(schedule)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(schedule.timeTitle) schedule")
        }
        .font(.callout)
        .opacity(schedule.enabled ? 1 : 0.5)
    }
}

private struct WarmUpClientCard: View {
    let client: WarmUpClient
    @Binding var configuration: WarmUpClientConfiguration
    @EnvironmentObject private var settings: WarmUpSettings
    @EnvironmentObject private var tracker: TrackerStatus
    @State private var expanded = false

    private var latest: WarmUpRun? { settings.state.latestRun(for: client) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProviderBadge(providerID: client.providerID)
                Text(client.title)
                    .font(.system(.headline, design: .rounded))
                Spacer()
                Button("Warm up now") { settings.runNow(client) }
                    .disabled(!tracker.isRunning || settings.isRunning(client))
            }
            HStack(spacing: 8) {
                if let failure = settings.failures[client] {
                    Text(failure).foregroundStyle(Brand.critical)
                } else if settings.isRunning(client) && tracker.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running")
                } else if let latest, let outcome = latest.outcome {
                    Text(outcome.title).foregroundStyle(WarmUpPalette.color(outcome))
                    Text(latest.finishedAt ?? latest.startedAt, style: .relative)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not run yet").foregroundStyle(.secondary)
                }
                Spacer()
                if let next = settings.nextRun(for: client) {
                    LabeledContent("Next run") {
                        Text(next, format: .dateTime.weekday(.abbreviated).hour().minute())
                    }
                    .fixedSize()
                    .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            DisclosureGroup("Configuration", isExpanded: $expanded) {
                VStack(spacing: 14) {
                    if client == .glm {
                        Picker("Endpoint", selection: $configuration.endpoint) {
                            ForEach(GLMEndpoint.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        GLMKeyField()
                    } else {
                        LabeledContent("Executable") {
                            TextField("Auto-detect", text: $configuration.executablePath)
                                .frame(maxWidth: 290)
                        }
                    }
                    LabeledContent("Model") {
                        TextField(client == .glm ? "glm-5.3" : "Default", text: $configuration.model)
                            .frame(maxWidth: 290)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 14)
            }
            .font(.callout)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct WarmUpRunRow: View {
    let run: WarmUpRun

    private var evidence: String {
        [run.model, run.detail, run.tokens.map { "\($0) tokens" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.isAutomatic ? "clock" : "hand.tap")
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text(run.startedAt, format: .dateTime.weekday(.abbreviated).hour().minute())
                .frame(width: 92, alignment: .leading)
            Text(run.client.title)
                .frame(width: 90, alignment: .leading)
            Text(run.outcome?.title ?? "Running")
                .foregroundStyle(run.outcome.map(WarmUpPalette.color) ?? .secondary)
                .lineLimit(1)
            Spacer(minLength: 10)
            Text(evidence)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if let duration = run.duration, duration > 0 {
                Text(String(format: "%.1fs", duration))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .font(.caption.monospacedDigit())
    }
}

private enum WarmUpPalette {
    static func color(_ outcome: WarmUpOutcome) -> Color {
        switch outcome {
        case .succeeded: .secondary
        case .skipped: Brand.warning
        case .failed: Brand.critical
        case .cancelled: .secondary
        }
    }
}

private struct GLMKeyField: View {
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var error: String?

    var body: some View {
        LabeledContent("API key") {
            HStack {
                SecureField(hasSavedKey ? "Saved in Keychain" : "API key", text: $key)
                Button("Save") { save(key) }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasSavedKey {
                    Button("Remove", role: .destructive) { save("") }
                }
            }
            .frame(maxWidth: 360)
        }
        .onAppear {
            do { hasSavedKey = try GLMCredentials.savedKey() != nil }
            catch { self.error = error.localizedDescription }
        }
        .alert("API key", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save(_ value: String) {
        do {
            try GLMCredentials.save(value)
            hasSavedKey = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            key = ""
        } catch { self.error = error.localizedDescription }
    }
}
