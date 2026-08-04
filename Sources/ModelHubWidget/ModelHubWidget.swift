import SwiftUI
import WidgetKit
import ModelHubWidgetSupport

struct ModelHubWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: ModelHubWidgetSnapshot
}

struct ModelHubWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ModelHubWidgetEntry {
        ModelHubWidgetEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ModelHubWidgetEntry) -> Void) {
        completion(
            ModelHubWidgetEntry(
                date: Date(),
                snapshot: context.isPreview
                    ? .placeholder
                    : ModelHubWidgetSnapshotStore.load() ?? offlineSnapshot
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ModelHubWidgetEntry>) -> Void) {
        let entry = ModelHubWidgetEntry(
            date: Date(),
            snapshot: ModelHubWidgetSnapshotStore.load() ?? offlineSnapshot
        )
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private var offlineSnapshot: ModelHubWidgetSnapshot {
        ModelHubWidgetSnapshot(
            isServerRunning: false,
            endpoint: "127.0.0.1:11435/v1",
            providerCount: 0,
            routeCount: 0,
            availableModelCount: 0,
            totalRequests: 0,
            successfulRequests: 0
        )
    }
}

struct ModelHubWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ModelHubWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("模型枢纽", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(entry.snapshot.isServerRunning ? Color.green : Color.secondary)
                    .frame(width: 9, height: 9)
            }

            Text(entry.snapshot.isServerRunning ? "本地网关运行中" : "本地网关未运行")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(entry.snapshot.isServerRunning ? .primary : .secondary)

            HStack(spacing: 14) {
                metric("可用模型", value: entry.snapshot.availableModelCount)
                metric("请求", value: entry.snapshot.totalRequests)
                if family != .systemSmall {
                    metric("供应商", value: entry.snapshot.providerCount)
                    metric("路由", value: entry.snapshot.routeCount)
                }
            }

            if family != .systemSmall {
                HStack {
                    Text(entry.snapshot.endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let rate = entry.snapshot.successRate {
                        Text("成功率 \(rate)%")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func metric(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title3.monospacedDigit().weight(.bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct ModelHubStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ModelHubWidgetSnapshotStore.widgetKind, provider: ModelHubWidgetProvider()) { entry in
            ModelHubWidgetView(entry: entry)
        }
        .configurationDisplayName("模型枢纽状态")
        .description("查看本地网关、可用模型和请求状态。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ModelHubWidgetBundle: WidgetBundle {
    var body: some Widget {
        ModelHubStatusWidget()
    }
}
