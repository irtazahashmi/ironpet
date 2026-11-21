import ActivityKit
import Foundation
import IronPetKit

/// Shared with the widget extension so the Live Activity and the Home Screen widget stay one kind.
enum PetWidgetKind {
    static let id = "IronPetPet"
}

/// Attributes for the pet Live Activity on the Lock Screen and Dynamic Island.
struct PetActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var mood: String
        var badge: Int
        var name: String

        var moodLabel: String { PetMoodLabel.text(mood) }
    }

    var name: String
}
