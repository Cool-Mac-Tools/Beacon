import SwiftUI
import AppKit

struct AISearchTraceView: View {
    let trace: AISearchTrace
    let running: Bool
    let cancel: () -> Void
    @State private var expanded = false
    @State private var follow = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button { expanded.toggle() } label: {
                    Label("Search activity · \(trace.steps.count) steps", systemImage: running || expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain)
                if running {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(String(format: "%.0fs", max(0, timeline.date.timeIntervalSince(trace.startedAt))))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if running {
                    Toggle("Follow live", isOn: $follow).toggleStyle(.checkbox).font(.caption)
                    Button("Stop", action: cancel).controlSize(.small)
                }
                Button(copied ? "Copied" : "Copy log", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trace.text, forType: .string)
                    copied = true
                }.controlSize(.small).disabled(trace.steps.isEmpty)
            }.padding(.horizontal, 18).padding(.vertical, 10)
            if running || expanded {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(trace.steps) { step in
                                HStack(alignment: .top, spacing: 10) {
                                    if step.state == .running { ProgressView().controlSize(.small).frame(width: 16) }
                                    else { Image(systemName: step.state == .complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                        .foregroundStyle(step.state == .complete ? Color.green : step.state == .failed ? .red : .orange).frame(width: 16) }
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(step.title).font(.system(size: 12, weight: .semibold))
                                            Spacer()
                                            if let end = step.finishedAt {
                                                Text(String(format: "%.1fs", max(0, end.timeIntervalSince(step.startedAt))))
                                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                            }
                                        }
                                        if !step.detail.isEmpty {
                                            Text(step.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }.id(step.id)
                            }
                        }.padding(18)
                    }
                    .onChange(of: trace.steps) { _ in
                        copied = false
                        if running && follow, let last = trace.steps.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }.frame(maxHeight: running ? .infinity : 250)
            }
        }
        .background(Color.accentColor.opacity(0.035))
    }
}
