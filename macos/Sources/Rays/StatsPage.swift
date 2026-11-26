import Charts
import SwiftUI

/// What finished downloads added up to over the last 7, 30 or 90 days.
struct StatsPage: View {
    @Environment(EngineModel.self) private var model
    @AppStorage("statsDays") private var days = 30
    @State private var stats: Stats?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.gap) {
                    header
                    Picker("Range", selection: $days) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if let stats, stats.totalFiles > 0 {
                        figures(stats)
                        Text("Downloaded per day").font(.headline).padding(.top, 4)
                        chart(stats)
                        Text("Top sites").font(.headline).padding(.top, 4)
                        sites(stats)
                    } else {
                        Text("No finished downloads in this range.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    Text("Stats count downloads still in your list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, LayoutMetrics.margin)
                .padding(.bottom, LayoutMetrics.margin)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Stats")
            .toolbar { ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() } }
        }
        .task(id: days) { stats = model.stats(days: UInt32(days)) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: LayoutMetrics.gap) {
            IconTile(.stats, size: TileSize.hero)
            VStack(alignment: .leading, spacing: 6) {
                Text("Stats").font(.title2.weight(.semibold))
                Text("How much you downloaded, and from where.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 10)
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
                .foregroundStyle(Color.green)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(UInt64.self) { Text(v == 0 ? "0" : byteText(v)) } }
            }
        }
        .frame(height: 180)
    }

    private func sites(_ s: Stats) -> some View {
        let biggest = max(s.topHosts.first?.bytes ?? 1, 1)
        return VStack(spacing: 0) {
            ForEach(s.topHosts, id: \.host) { h in
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
                                Capsule().fill(Color.green).frame(width: g.size.width * Double(h.bytes) / Double(biggest))
                            }
                        }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
