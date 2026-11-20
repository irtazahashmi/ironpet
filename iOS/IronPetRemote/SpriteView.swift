import IronPetKit
import SwiftUI

/// Plays the pet's current row. A one-shot row settles into its follow-up row, and Reduce Motion shows one still frame.
struct SpriteView: View {
    let atlas: Atlas?
    let row: AtlasRow
    let followUp: AtlasRow?
    let started: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let atlas {
            if reduceMotion {
                frame(atlas, SpriteTimeline.Position(row: .idle, frame: 0))
            } else {
                TimelineView(.animation) { context in
                    frame(atlas, SpriteTimeline.position(row: row, followUp: followUp, elapsed: context.date.timeIntervalSince(started)))
                }
            }
        } else {
            Image(systemName: "pawprint.fill").resizable().scaledToFit().padding(48).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func frame(_ atlas: Atlas, _ position: SpriteTimeline.Position) -> some View {
        if let image = atlas.frame(position.row, position.frame) {
            Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit()
        }
    }
}
