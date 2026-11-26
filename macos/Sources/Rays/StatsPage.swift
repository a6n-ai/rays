import Charts
import SwiftUI

/// What finished downloads added up to over the last 7, 30 or 90 days.
struct StatsPage: View {
    @Environment(EngineModel.self) private var model
    @AppStorage("statsDays") private var days = 30
    @State private var stats: Stats?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HeroCard(.stats, title: "Stats", subtitle: "How much you downloaded, and from where.",
                             learnMore: URL(string: "https://rays.a6n.ai/docs/app/stats/"))
                }
                if let stats, stats.totalFiles > 0 {
                    Section { figures(stats) }
                }
                Section {
                    ChartCard("Downloaded per day", range: $days, ranges: [(7, "7 days"), (30, "30 days"), (90, "90 days")]) {
                        if let stats, stats.totalFiles > 0 {
                            chart(stats)
                        } else {
                            Text("No finished downloads in this range.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } footer: {
                    Text("Stats count downloads still in your list.")
                }
                if let stats, stats.totalFiles > 0 {
                    Section("Top sites") { sites(stats) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Stats")
        }
        .task(id: days) { stats = model.stats(days: UInt32(days)) }
    }

    private func figures(_ s: Stats) -> some View {
        HStack(alignment: .top, spacing: LayoutMetrics.gap) {
            figure("Downloaded", byteText(s.totalBytes))
            figure("Files", s.totalFiles.formatted())
            figure("Average speed", s.avgBps.map { SpeedFormat.mbps($0) } ?? "—")
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func chart(_ s: Stats) -> some View {
        Chart(s.perDay, id: \.day) { d in
            BarMark(x: .value("Day", Date(timeIntervalSince1970: TimeInterval(d.day)), unit: .day), y: .value("Bytes", d.bytes))
                .foregroundStyle(TilePalette.green)
                .cornerRadius(2)
        }
        .chartYAxis {
            trailingAxis(values: .automatic) { value in
                value.as(UInt64.self).map { $0 == 0 ? "0" : byteText($0) }
            }
        }
        .transaction { $0.animation = nil }
        .accessibilityLabel("Downloaded per day")
    }

    private func sites(_ s: Stats) -> some View {
        let biggest = max(s.topHosts.first?.bytes ?? 1, 1)
        return ForEach(s.topHosts, id: \.host) { h in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(h.host).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: LayoutMetrics.gap)
                    Text("\(h.files) \(h.files == 1 ? "file" : "files")").foregroundStyle(.secondary)
                    Text(byteText(h.bytes)).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                }
                Capsule().fill(.quaternary).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(TilePalette.green).frame(width: g.size.width * Double(h.bytes) / Double(biggest))
                        }
                    }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
