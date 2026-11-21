import Foundation
import IronPetKit

/// The picture behind the chat transcript: a built-in gradient with an optional tiled doodle pattern, or an image the
/// user picked. The built-in table and its drawing live in IronPetKit (`ChatBackgrounds`), so the iPhone app draws the same
/// ones. The Mac adds importing an image and caching the decoded custom image (`ChatBackground` in the Mac target).
package enum ChatBackground {
    package static let defaultID = ChatBackgrounds.defaultID
    package static let customID = ChatBackgrounds.customID

    package typealias Doodle = ChatBackgrounds.Doodle
    package typealias BuiltIn = ChatBackgrounds.BuiltIn

    package static var builtIns: [BuiltIn] { ChatBackgrounds.builtIns }

    package static func builtIn(_ id: String) -> BuiltIn? { ChatBackgrounds.builtIn(id) }

    /// Where imported images live, inside ironpet's own data folder.
    package static let folder = Paths.root.appendingPathComponent("backgrounds")
}
