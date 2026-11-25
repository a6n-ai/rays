import SwiftUI

/// The right pane: name, next run, enabled switch, the Schedule and Files tabs, and the footer.
struct SchedulerEditor: View {
    @Binding var draft: QueueConfig
    let queue: QueueView
    let isDirty: Bool
    let saveError: String?
    let onSave: () -> Void
    let onRevert: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @Environment(EngineModel.self) private var model
    @State private var tab = Tab.schedule
    @State private var confirmDelete = false

    private enum Tab: Hashable { case schedule, files }

    private var jobs: [JobView] { model.jobs.filter { $0.queueId == queue.id } }

    private var problem: Bool {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if case .days(let mask)? = draft.schedule?.repeat, mask == 0 { return true }
        if case .command(let command) = draft.whenFinished, command.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return false
    }

    private var pillText: String {
        if isDirty { return "Save to update" }
        guard draft.schedule != nil, draft.enabled else { return "Not scheduled" }
        return queue.nextRun.map { "Next run " + SchedulerTime.nextRunText($0) } ?? "No upcoming run"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch tab {
            case .schedule:
                ScrollView { SchedulerForm(draft: $draft).padding(LayoutMetrics.margin) }
            case .files:
                files
            }
            Divider()
            footer
        }
        .confirmationDialog("Delete \(queue.config.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Queue", role: .destructive, action: onDelete)
        } message: {
            Text("Its downloads move to Main.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.gap) {
            HStack(spacing: LayoutMetrics.gap) {
                TextField("Queue name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                Label(pillText, systemImage: "clock")
                    .font(.callout)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                Toggle("Enabled", isOn: $draft.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Enabled")
                Button(action: onClose) { Image(systemName: "xmark").font(.body.weight(.medium)) }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Give the queue a name.").font(.caption).foregroundStyle(.red)
            }
            Picker("Section", selection: $tab) {
                Text("Schedule").tag(Tab.schedule)
                Text("Files (\(jobs.count))").tag(Tab.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
        }
        .padding([.horizontal, .top], LayoutMetrics.margin)
        .padding(.bottom, LayoutMetrics.gap)
    }

    @ViewBuilder private var files: some View {
        if jobs.isEmpty {
            EmptyState(symbol: "tray", title: "No downloads in this queue",
                       message: "Use Move to Queue on a download, or pick this queue when you add one.")
        } else {
            List(jobs, id: \.id) { job in
                JobRow(job: job)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: LayoutMetrics.gap) {
                    Button { model.runQueueNow(queue.id) } label: { Label("Run now", systemImage: "play.fill") }
                        .buttonStyle(.glass)
                    if queue.id != 1 {
                        Button("Delete Queue") { confirmDelete = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .frame(minHeight: 28)
                    }
                    Spacer()
                    Button("Revert", action: onRevert)
                        .buttonStyle(.plain)
                        .frame(minHeight: 28)
                        .disabled(!isDirty)
                    Button("Save schedule", action: onSave)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isDirty || problem)
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LayoutMetrics.margin)
    }
}
