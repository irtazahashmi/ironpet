import IronPetKit
import SwiftUI
import UIKit

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let message = model.errorMessage {
                        Label(message, systemImage: SharedSymbols.warning).foregroundStyle(.orange).accessibilityIdentifier("pet-error")
                    }
                    hero
                    ForEach(model.bubbles) { BubbleCard(bubble: $0, model: model) }
                    tricks
                    TodayList(model: today, open: open)
                }
                .padding()
            }
            .navigationTitle(model.pet?.name ?? "Pet")
            .themedScreen()
            .refreshable { await model.refresh(); await today.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDevice = true } label: { Image(systemName: SharedSymbols.settings) }
                        .accessibilityLabel("Device").accessibilityIdentifier("device-button")
                }
            }
            .sheet(isPresented: $showDevice) { SettingsView(app: app, client: client) }
        }
        .task { model.start(); today.start() }
    }

    /// The signature of the tab: the Mac's chat backdrop behind the sprite, mood on glass, tap for a trick.
    private var hero: some View {
        ZStack(alignment: .bottom) {
            ChatBackgroundPicture(id: model.backgroundID, customImage: model.backgroundImage.map(Image.init(uiImage:)),
                                  fallback: SharedTheme.window)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Button { Task { await nudge() } } label: {
                    SpriteView(atlas: model.atlas, row: model.row, followUp: model.followUp, started: model.moodStarted)
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("pet-sprite")
                .accessibilityLabel(model.pet?.name ?? "Pet")
                .accessibilityValue(PetMoodLabel.text(model.mood))
                .accessibilityHint(model.pet?.tricks.isEmpty == false ? "Performs a trick" : "")
                .accessibilityAddTraits(.isButton)

                moodChip
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pet-hero")
    }

    private var moodChip: some View {
        HStack(spacing: 8) {
            Text(PetMoodLabel.text(model.mood)).font(.headline).accessibilityIdentifier("pet-mood")
            if model.badge > 0 {
                Text("\(model.badge)").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.red, in: Capsule()).accessibilityIdentifier("pet-badge")
                    .accessibilityLabel("\(model.badge) needing attention")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .chromeGlass(in: Capsule())
    }

    private var tricks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tricks").font(.headline)
            GlassGroup {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.pet?.tricks ?? [], id: \.self) { trick in
                            Button(trick) { Task { await play(trick) } }
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .interactiveGlass(in: Capsule())
                                .accessibilityIdentifier("trick-\(trick)")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nudge() async {
        guard let trick = model.pet?.tricks.first else { return }
        await play(trick)
    }

    private func play(_ trick: String) async {
        if !reduceMotion {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        await model.perform(trick: trick)
    }
}

/// A bubble on the Mac's screen. A bubble whose buttons decide something only the Mac may decide says so instead of showing them.
struct BubbleCard: View {
    @Environment(\.macAccent) private var macAccent
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
                            .tint(action.style == "primary" ? macAccent : nil)
                            .accessibilityIdentifier("bubble-action-\(action.id)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .chromeGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        // Glass sits on the Button, not inside the label — glassEffect on label content can swallow taps on iOS 26.
        Button { open(item.target) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol).frame(width: 28)
                VStack(alignment: .leading) {
                    Text(item.title).foregroundStyle(.primary)
                    if let subtitle = item.subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
                    if tab == nil { Text("Open on the Mac").font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if tab != nil { Image(systemName: SharedSymbols.chevron).foregroundStyle(.tertiary) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chromeGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(tab == nil)
        .accessibilityIdentifier("today-item-\(item.id)")
    }
}
