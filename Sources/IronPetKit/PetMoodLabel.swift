import Foundation

/// Human-readable mood names shared by the Pet tab, the widget and Live Activities.
public enum PetMoodLabel {
    public static func text(_ mood: String) -> String {
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

    /// Moods that mean the person should look at the Mac or open the phone app.
    public static func needsAttention(_ mood: String) -> Bool {
        switch mood {
        case "needsInput", "failed", "working": return true
        default: return false
        }
    }
}
