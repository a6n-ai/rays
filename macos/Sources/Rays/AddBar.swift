import SwiftUI

struct AddBar: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var fieldFocused: Bool
    @State private var input = ""
    @Namespace private var glass
    let isTargeted: Bool

    private var isBlank: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isExpanded: Bool { fieldFocused || !isBlank }

    /// Web links found in what was typed or pasted; text around them is ignored, as on submit.
    private var links: [String] { isBlank ? [] : Links.inText(input) }
    private var linkCount: String { links.count == 1 ? "1 link" : "\(links.count) links" }

    var body: some View {
        GlassEffectContainer(spacing: LayoutMetrics.gap) {
            HStack(spacing: LayoutMetrics.gap) {
                field
                downloadButton
            }
            // An overlay takes no layout space, so the bar does not move when a notice appears.
            .overlay(alignment: .top) {
                if let notice = model.notice {
                    noticeCapsule(notice)
                        .alignmentGuide(.top) { d in d[.bottom] + LayoutMetrics.gap }
                }
            }
        }
        .frame(maxWidth: LayoutMetrics.barMaxWidth)
        .background {
            // Zero-size, invisible button: exists only to own the ⌘L shortcut.
            Button("Add Link") { fieldFocused = true }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isTargeted)
        .animation(reduceMotion ? nil : .smooth, value: model.notice)
        .animation(reduceMotion ? nil : .smooth, value: isExpanded)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LayoutMetrics.margin)
        .padding(.bottom, LayoutMetrics.margin)
        // Clearing the field after a submit must keep the notice that submit just produced.
        .onChange(of: input) { _, new in if !new.isEmpty { model.clearNotice() } }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            model.clearNotice()
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(.secondary)
            TextField(isTargeted ? "Drop to download" : "Paste links in any format: lines, commas, CSV…", text: $input, axis: .horizontal)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onReceive(NotificationCenter.default.publisher(for: .focusAddBar)) { _ in fieldFocused = true }
                .onSubmit(submit)
            if !isBlank {
                Group {
                    if links.isEmpty {
                        Label("No link found", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    } else {
                        Label(linkCount, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .font(.callout)
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .transition(.opacity)
                .accessibilityLabel(links.isEmpty ? "No link found" : "\(linkCount) ready")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: LayoutMetrics.barHeight, maxHeight: LayoutMetrics.barHeight)
        .glassEffect(isTargeted && !reduceTransparency ? .regular.tint(.accentColor) : .regular, in: .capsule)
    }

    /// Plain style with an explicit glass shape: the glass button styles pad the label, so the frame could not pin the height.
    @ViewBuilder private var downloadButton: some View {
        let ready = !links.isEmpty
        let dimmed = !isEnabled || !ready
        // Always the round icon; a pasted link fills it with the accent colour instead of growing a label.
        Button(action: submit) {
            Label("Download", systemImage: "arrow.down")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ready ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.tint))
                .frame(width: LayoutMetrics.barHeight, height: LayoutMetrics.barHeight)
                .glassEffect(ready ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
                .glassEffectID("download", in: glass)
                .contentShape(Circle())
                .opacity(dimmed ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .help(links.isEmpty ? "Paste a link that starts with http:// or https://" : "Download \(linkCount)")
    }

    private func noticeCapsule(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: LayoutMetrics.barMaxWidth)
        .glassEffect(reduceTransparency ? .regular : .regular.tint(Color.red.opacity(0.2)), in: .capsule)
        .glassEffectID("notice", in: glass)
        .glassEffectTransition(.matchedGeometry)
    }

    private func submit() {
        guard !isBlank else { return }
        model.add(input)
        input = ""
    }
}
