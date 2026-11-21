import ActivityKit
import Foundation
import IronPetKit
import WidgetKit

/// Starts, updates and ends the pet Live Activity, and asks WidgetKit to reload after a snapshot write.
@MainActor
enum PetPresence {
    static func update(_ snapshot: PetSnapshot) {
        WidgetCenter.shared.reloadTimelines(ofKind: PetWidgetKind.id)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = PetActivityAttributes.ContentState(mood: snapshot.mood, badge: snapshot.badge, name: snapshot.name)
        if snapshot.needsAttention {
            if let activity = Activity<PetActivityAttributes>.activities.first {
                Task { await activity.update(.init(state: state, staleDate: nil)) }
            } else {
                let attributes = PetActivityAttributes(name: snapshot.name)
                _ = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
            }
        } else {
            for activity in Activity<PetActivityAttributes>.activities {
                Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate) }
            }
        }
    }

    static func endAll() {
        for activity in Activity<PetActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
