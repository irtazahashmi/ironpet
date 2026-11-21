import AppKit
import Foundation
import IronPetCore
import IronPetKit

/// What plays on a gallery tile: a few of the pet's own rows, with the pet's own frame durations.
enum PetPreview {
    static let sequence: [(row: AtlasRow, passes: Int)] = [(.idle, 2), (.waving, 1), (.jumping, 1), (.running, 2)]

    /// The row and frame index showing `time` seconds into the loop. With Reduce Motion on, always idle frame 0.
    static func position(in atlas: Atlas, at time: Double, reduceMotion: Bool) -> (row: AtlasRow, frame: Int) {
        guard !reduceMotion else { return (.idle, 0) }
        let segments = sequence.filter { atlas.has($0.row) }
        let lengths = segments.map { Double($0.passes) * $0.row.durations.reduce(0, +) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return (.idle, 0) }
        var t = time.truncatingRemainder(dividingBy: total)
        if t < 0 { t += total }
        for (segment, length) in zip(segments, lengths) {
            guard t >= length else {
                let pass = segment.row.durations.reduce(0, +)
                t = t.truncatingRemainder(dividingBy: pass)
                var index = 0
                while index < segment.row.durations.count - 1, t >= segment.row.durations[index] {
                    t -= segment.row.durations[index]
                    index += 1
                }
                return (segment.row, index)
            }
            t -= length
        }
        return (.idle, 0)
    }

    static func frame(in atlas: Atlas, at time: Double, reduceMotion: Bool) -> CGImage? {
        let (row, index) = position(in: atlas, at: time, reduceMotion: reduceMotion)
        return atlas.frame(row, index)
    }
}

/// What "Build a new pet" sends: the `ironpet-pets` skill, called by name. The skill holds the atlas layout and the steps.
enum PetPrompt {
    static let skillName = "ironpet-pets"

    static func build(description: String) -> String {
        "/\(skillName) \(description.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Whether an agent on this Mac has the skill.
    static var isSkillInstalled: Bool {
        SkillManager.standard.entries().first { $0.skill.name == skillName }?.status.isInstalledAnywhere ?? false
    }

    /// Installs the skill for the agents found on this Mac when none has it, the way Settings → Skills does.
    static func ensureSkillInstalled() {
        guard !isSkillInstalled else { return }
        do { try SkillManager.standard.install(names: [skillName]) } catch { NSLog("ironpet: could not install the \(skillName) skill: \(error)") }
    }
}
