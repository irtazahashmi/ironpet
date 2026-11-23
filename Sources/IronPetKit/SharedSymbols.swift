import Foundation

/// The SF Symbol for every concept that has an icon on both the Mac app and the iPhone app. Both apps read their symbol names
/// from here, so a concept cannot get a different icon on each. Where the two had drifted, the Mac's symbol won. Every name
/// exists on macOS 14 and iOS 17, the deployment targets.
public enum SharedSymbols {
    // Sections and tabs
    public static let pet = "pawprint.fill"
    public static let chat = "bubble.left.and.bubble.right"
    public static let tasks = "checklist"
    public static let agents = "person.2"
    public static let more = "ellipsis.circle"
    public static let alerts = "bell"
    public static let automations = "clock.badge.checkmark"
    public static let screen = "rectangle.dashed.badge.record"
    public static let settings = "gearshape"
    public static let chatOptions = "slider.horizontal.3"
    public static let find = "magnifyingglass"
    public static let meetings = "waveform"

    // Chat and composer actions
    public static let newChat = "square.and.pencil"
    public static let history = "clock.arrow.circlepath"
    public static let attach = "paperclip"
    public static let microphone = "mic"
    public static let microphoneActive = "mic.fill"
    public static let send = "arrow.up"
    public static let stop = "stop.fill"
    public static let removeAttachment = "xmark.circle.fill"
    public static let photo = "photo"
    public static let file = "doc"
    public static let copy = "doc.on.doc"
    public static let reply = "arrowshape.turn.up.left"
    public static let jumpToLatest = "arrow.down"
    public static let speak = "speaker.wave.2"
    public static let stopSpeaking = "stop.circle.fill"
    public static let sentAt = "clock"

    // Prompts and states
    public static let approval = "hand.raised.fill"
    public static let question = "questionmark.bubble.fill"
    public static let skip = "forward"
    public static let allow = "checkmark"
    public static let deny = "xmark"
    public static let warning = "exclamationmark.triangle.fill"
    public static let done = "checkmark.circle.fill"
    public static let chevron = "chevron.right"

    // Where a chat message came from
    public static let sourceTelegram = "paperplane.fill"
    public static let sourceAutomation = "clock.arrow.circlepath"
    public static let sourceJob = "shippingbox.fill"
    public static let sourceVoice = "mic.fill"
    public static let sourceIPhone = "iphone"
}
