import IronPetKit
import SwiftUI

/// The Pet tab: the animated pet with its mood and badge, the bubbles on the Mac's screen with their buttons, the tricks and, below,
/// today's brief and recap. Today sits here because a five-tab bar is full, and the pet's mood, bubbles and today's list answer the
/// same question: what needs me right now.
struct PetView: View {
    let model: PetModel
    let today: TodayModel
    let app: AppModel
    let client: IronPetClient
    let open: (TodayTarget) -> Void
    @State private var showDevice = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("pet-error")
                    }
                    header
                    ForEach(model.bubbles) { BubbleCard(bubble: $0, model: model) }
                    tricks
                    TodayList(model: today, open: open)
                }
                .padding()
            }
            .navigationTitle(model.pet?.name ?? "Pet")
            .refreshable { await model.refresh(); await today.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDevice = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Device").accessibilityIdentifier("device-button")
                }
            }
            .sheet(isPresented: $showDevice) { SettingsView(app: app, client: client) }
        }
        .task { model.start(); today.start() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            SpriteView(atlas: model.atlas, row: model.row, followUp: model.followUp, started: model.moodStarted)
                .frame(height: 220)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("pet-sprite")
                .accessibilityLabel("Pet")
                .accessibilityValue("row \(model.row.index)")
            HStack(spacing: 8) {
                Text(Self.label(model.mood)).font(.headline).accessibilityIdentifier("pet-mood")
                if model.badge > 0 {
                    Text("\(model.badge)").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.red, in: Capsule()).accessibilityIdentifier("pet-badge")
                }
            }
        }
    }

    private var tricks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tricks").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(model.pet?.tricks ?? [], id: \.self) { trick in
                        Button(trick) { Task { await model.perform(trick: trick) } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("trick-\(trick)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func label(_ mood: String) -> String {
        switch mood {
        case "needsInput": return "Needs you"
        case "working": return "Working"
        case "done": return "Done"
        case "failed": return "Failed"
        case "listening": return "Listening"
        case "sleeping": return "Sleeping"
        case "drinking": return "Drinking"
        case "stretching": return "Stretching"
        case "attentive": return "Watching"
        default: return "Idle"
        }
    }
}

/// A bubble on the Mac's screen. A bubble whose buttons decide something only the Mac may decide says so instead of showing them.
struct BubbleCard: View {
    let bubble: RemoteBubble
    let model: PetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(bubble.title, systemImage: bubble.symbol).font(.headline)
            if let subtitle = bubble.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            if let body = bubble.body { Text(body).font(.callout) }
            ForEach(bubble.lines, id: \.self) { Text($0).font(.callout) }
            if bubble.macOnly {
                Text("Answer on the Mac").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).accessibilityIdentifier("mac-only-\(bubble.id)")
            } else if !bubble.actions.isEmpty {
                HStack {
                    ForEach(bubble.actions) { action in
                        Button(action.title, role: action.style == "destructive" ? .destructive : nil) { Task { await model.press(bubble, action) } }
                            .buttonStyle(.bordered)
                            .tint(action.style == "primary" ? .accentColor : nil)
                            .accessibilityIdentifier("bubble-action-\(action.id)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bubble-\(bubble.id)")
    }
}

/// The brief and the recap. A row that points at a task, an agent session or an alert switches to that tab.
struct TodayList: View {
    let model: TodayModel
    let open: (TodayTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Today", selection: Binding(get: { model.kind }, set: { model.kind = $0 })) {
                Text("Brief").tag(TodayModel.Kind.brief)
                Text("Recap").tag(TodayModel.Kind.recap)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("today-kind")
            if let today = model.today {
                if today.isEmpty { Text(model.kind == .brief ? "Nothing needs you this morning." : "Quiet day: nothing finished or closed today.").foregroundStyle(.secondary) }
                ForEach(today.sections.filter { !$0.items.isEmpty }) { section in
                    Text(section.title).font(.headline).accessibilityIdentifier("today-section-\(section.id)")
                    ForEach(section.items) { item in row(item) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(_ item: TodayItem) -> some View {
        let tab = AppTab.tab(for: item.target)
        Button { open(item.target) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol).frame(width: 28)
                VStack(alignment: .leading) {
                    Text(item.title).foregroundStyle(.primary)
                    if let subtitle = item.subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                    if tab == nil { Text("Open on the Mac").font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if tab != nil { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(tab == nil)
        .accessibilityIdentifier("today-item-\(item.id)")
    }
}
