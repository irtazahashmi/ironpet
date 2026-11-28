import Foundation

/// Whose voice a line is: the microphone is "Me", the recorded app is "Them". A room meeting has one track, the
/// microphone alone, called "Room" because several people speak into it.
package enum MeetingTrack: String, CaseIterable, Comparable {
    case me = "Me"
    case them = "Them"
    case room = "Room"

    /// File prefix of a track's chunks: `mic-001.wav`, `them-001.wav`, `room-001.wav`.
    package var filePrefix: String {
        switch self {
        case .me: return "mic"
        case .them: return "them"
        case .room: return "room"
        }
    }

    /// Tracks that carry more than one voice, so speaker recognition splits them.
    package var hasSeveralVoices: Bool { self != .me }

    private var rank: Int {
        switch self {
        case .me: return 0
        case .them: return 1
        case .room: return 2
        }
    }

    package static func < (lhs: MeetingTrack, rhs: MeetingTrack) -> Bool { lhs.rank < rhs.rank }
}

/// One line of the transcript, with `start` in seconds from the start of the meeting.
package struct MeetingLine: Equatable {
    package init(track: MeetingTrack, start: TimeInterval, text: String, speakerId: Int? = nil, speaker: String? = nil) {
        self.track = track
        self.start = start
        self.text = text
        self.speakerId = speakerId
        self.speaker = speaker
    }

    package var track: MeetingTrack
    package var start: TimeInterval
    package var text: String
    /// Which voice of the meeting spoke, when speaker recognition ran on this line's chunk. Only "Them" and "Room" lines have one.
    package var speakerId: Int?
    /// What the line shows in place of "Them": a name, or "Speaker 2" until the user names that voice.
    package var speaker: String?

    package var label: String { speaker ?? track.rawValue }
}

/// Who spoke from `start` to `end`, in seconds from the start of the chunk.
package struct SpeakerTurn: Equatable {
    package init(speakerId: Int, start: TimeInterval, end: TimeInterval) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
    }

    package var speakerId: Int
    package var start: TimeInterval
    package var end: TimeInterval
}

/// A stretch of audio that could not be transcribed.
package struct MissedRange: Equatable {
    package init(track: MeetingTrack, start: TimeInterval, end: TimeInterval, reason: String) {
        self.track = track
        self.start = start
        self.end = end
        self.reason = reason
    }

    package var track: MeetingTrack
    package var start: TimeInterval
    package var end: TimeInterval
    package var reason: String
}

/// Turns the segments of both tracks into `transcript.md`.
package enum MeetingTranscript {
    /// Moves a chunk's segments to meeting time. `offset` is where the chunk starts in the meeting.
    package static func lines(from segments: [TimedSegment], track: MeetingTrack, offset: TimeInterval,
                      turns: [SpeakerTurn] = []) -> [MeetingLine] {
        segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isSilenceOnly(text) else { return nil }
            return MeetingLine(track: track, start: offset + max(0, segment.start), text: text,
                               speakerId: track.hasSeveralVoices ? speaker(for: segment, in: turns) : nil)
        }
    }

    /// The speaker whose turns cover at least half of the segment. Anything less keeps the track name.
    package static func speaker(for segment: TimedSegment, in turns: [SpeakerTurn]) -> Int? {
        let length = segment.end - segment.start
        guard length > 0 else { return nil }
        var overlap: [Int: TimeInterval] = [:]
        for turn in turns {
            let shared = min(segment.end, turn.end) - max(segment.start, turn.start)
            if shared > 0 { overlap[turn.speakerId, default: 0] += shared }
        }
        // Ties go to the lower id, so the result does not depend on dictionary order.
        guard let best = overlap.min(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }),
              best.value / length >= 0.5 else { return nil }
        return best.key
    }

    /// Empty text, punctuation only, or the markers some models print for quiet audio, such as `[BLANK_AUDIO]`.
    package static func isSilenceOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces).contains($0) }) {
            return true
        }
        let marker = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]()* "))
        return ["blank_audio", "silence", "blank audio", "no speech", "music", "inaudible"].contains(marker)
            && (trimmed.hasPrefix("[") || trimmed.hasPrefix("(") || trimmed.hasPrefix("*"))
    }

    package static func render(startedAt: Date, appName: String, lines: [MeetingLine], missed: [MissedRange] = [],
                       timeZone: TimeZone = .current) -> String {
        enum Entry {
            case line(MeetingLine)
            case missed(MissedRange)
            package var start: TimeInterval {
                switch self {
                case .line(let line): return line.start
                case .missed(let range): return range.start
                }
            }
            package var track: MeetingTrack {
                switch self {
                case .line(let line): return line.track
                case .missed(let range): return range.track
                }
            }
        }
        let entries = (lines.map(Entry.line) + missed.map(Entry.missed)).enumerated()
            .sorted { a, b in
                if a.element.start != b.element.start { return a.element.start < b.element.start }
                if a.element.track != b.element.track { return a.element.track < b.element.track }
                return a.offset < b.offset
            }
            .map(\.element)

        var out = "# Meeting \(stamp(startedAt, timeZone: timeZone)) (\(appName))\n"
        var seenMissed = Set<String>()
        for entry in entries {
            switch entry {
            case .line(let line):
                out += "[\(clock(startedAt, plus: line.start, timeZone: timeZone))] \(line.label): \(line.text)\n"
            case .missed(let range):
                let text = "[\(clock(startedAt, plus: range.start, timeZone: timeZone))–"
                    + "\(clock(startedAt, plus: range.end, timeZone: timeZone))] (not transcribed: \(range.reason))"
                if seenMissed.insert(text).inserted { out += text + "\n" }
            }
        }
        return out
    }

    /// `2026-11-14 14:00`
    package static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyy-MM-dd HH:mm", timeZone).string(from: date)
    }

    /// `14:02:10`, the wall-clock time `seconds` into a meeting that started at `start`.
    package static func clock(_ start: Date, plus seconds: TimeInterval, timeZone: TimeZone = .current) -> String {
        formatter("HH:mm:ss", timeZone).string(from: start.addingTimeInterval(seconds.rounded(.down)))
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// Folder name for a meeting that started at `date`: `2026-11-14-1400`.
    package static func folderName(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("yyyy-MM-dd-HHmm", timeZone).string(from: date)
    }

    /// `hh:mm:ss` for an elapsed time, used in failure reasons and the panel.
    package static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
