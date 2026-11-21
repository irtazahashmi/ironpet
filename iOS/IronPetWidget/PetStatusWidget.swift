import IronPetKit
import SwiftUI
import WidgetKit

struct PetStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> PetStatusEntry {
        PetStatusEntry(date: Date(), snapshot: PetSnapshot(name: "Ghost", mood: "idle", badge: 0))
    }

    func getSnapshot(in context: Context, completion: @escaping (PetStatusEntry) -> Void) {
        completion(PetStatusEntry(date: Date(), snapshot: PetSnapshotStore.load() ?? placeholder(in: context).snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PetStatusEntry>) -> Void) {
        let snapshot = PetSnapshotStore.load() ?? PetSnapshot(name: "IronPet", mood: "idle", badge: 0)
        let entry = PetStatusEntry(date: Date(), snapshot: snapshot)
        // The app reloads the timeline when the Mac mood changes; this is only a stale fallback.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct PetStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: PetSnapshot
}

struct PetStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PetWidgetKind.id, provider: PetStatusProvider()) { entry in
            PetStatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Pet")
        .description("See your Mac pet's mood and how much needs you.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct PetStatusWidgetView: View {
    let entry: PetStatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 2) {
                    Image(systemName: "pawprint.fill").font(.headline)
                    if entry.snapshot.badge > 0 {
                        Text("\(entry.snapshot.badge)").font(.caption2.bold())
                    }
                }
            }
            .accessibilityLabel("\(entry.snapshot.name), \(entry.snapshot.moodLabel)")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(entry.snapshot.name, systemImage: "pawprint.fill").font(.headline)
                Text(entry.snapshot.moodLabel).font(.caption)
                if entry.snapshot.badge > 0 {
                    Text("\(entry.snapshot.badge) need you").font(.caption2)
                }
            }
        case .systemMedium:
            HStack(spacing: 16) {
                Image(systemName: "pawprint.fill").font(.system(size: 36)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.snapshot.name).font(.headline)
                    Text(entry.snapshot.moodLabel).font(.title3.weight(.semibold))
                    if entry.snapshot.badge > 0 {
                        Text("\(entry.snapshot.badge) needing attention").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("All quiet").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        default:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "pawprint.fill").font(.title2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(entry.snapshot.name).font(.headline)
                Text(entry.snapshot.moodLabel).font(.subheadline.weight(.semibold))
                if entry.snapshot.badge > 0 {
                    Text("\(entry.snapshot.badge)").font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.red, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
