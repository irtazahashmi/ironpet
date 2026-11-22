import ActivityKit
import IronPetKit
import SwiftUI
import WidgetKit

struct PetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PetActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: SharedSymbols.pet).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.name).font(.headline)
                    Text(context.state.moodLabel).font(.subheadline)
                }
                Spacer()
                if context.state.badge > 0 {
                    Text("\(context.state.badge)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.red, in: Capsule())
                }
            }
            .padding()
            .activityBackgroundTint(Color.clear)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.name, systemImage: SharedSymbols.pet)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.badge > 0 {
                        Text("\(context.state.badge)").font(.title3.bold())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.moodLabel).font(.headline)
                }
            } compactLeading: {
                Image(systemName: SharedSymbols.pet)
            } compactTrailing: {
                if context.state.badge > 0 {
                    Text("\(context.state.badge)")
                } else {
                    Text(String(context.state.moodLabel.prefix(4)))
                }
            } minimal: {
                Image(systemName: SharedSymbols.pet)
            }
        }
    }
}
