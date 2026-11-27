import IronPetCore
import IronPetKit
import SwiftUI

/// The recording bar for dictation in other apps: a dark capsule with a recording dot, a live level meter made of
/// dots, and a round close button. The dot and the meter use the app's accent colour, the one the chat uses.
/// Stopping is the dictation shortcut (or Enter); closing discards the recording.
struct DictationPill: View {
    @ObservedObject var voice: VoiceController
    /// The app's accent. Previews pass others.
    var accent: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transcribing: Bool { voice.phase == .transcribing }

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
                .opacity(transcribing ? 0.4 : 1)
                .accessibilityHidden(true)
            DotMeter(levels: voice.levels, accent: accent, paused: transcribing, reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity)
                .frame(height: 14)
            Button { voice.cancel() } label: {
                Image(systemName: SharedSymbols.deny)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(transcribing ? "Cancel transcription" : "Discard recording")
            .accessibilityLabel(transcribing ? "Cancel transcription" : "Discard recording")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(width: DictationPill.size.width, height: DictationPill.size.height)
        .background(Color(white: 0.14, opacity: 0.96), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(transcribing ? "Transcribing dictation" : "Recording dictation")
    }

    static let size = CGSize(width: 190, height: 36)
}

/// Decides when the meter redraws. It polls the level buffer and bumps `frame` only when the levels changed, at most
/// 20 times a second, and not at all while the pill is hidden. SwiftUI redraws the meter when `frame` changes.
@MainActor
final class DotMeterDriver: ObservableObject {
    /// The fastest redraw rate while audio moves.
    static let liveInterval: TimeInterval = 1.0 / 20
    /// The rate for Reduce Motion, the transcribing state, and silence.
    static let slowInterval: TimeInterval = 0.25
    private static let idleAfter = 2.0

    @Published private(set) var frame = 0
    /// How many redraws the driver asked for. Tests read it.
    private(set) var drawCount = 0
    private(set) var running = false

    private let levels: LevelBuffer
    private var lastGeneration: Int
    private var quietFor: TimeInterval = 0
    private var slow: Bool
    private var timer: Timer?

    init(levels: LevelBuffer, slow: Bool) {
        self.levels = levels
        self.slow = slow
        lastGeneration = levels.generation - 1
    }

    static func interval(slow: Bool, quietFor: TimeInterval) -> TimeInterval {
        slow || quietFor >= idleAfter ? slowInterval : liveInterval
    }

    func setSlow(_ value: Bool) {
        guard value != slow else { return }
        slow = value
        if running { schedule() }
    }

    /// Starts polling, only while the pill is on screen.
    func setVisible(_ visible: Bool) {
        guard visible != running else { return }
        running = visible
        if visible { schedule() } else { timer?.invalidate(); timer = nil }
    }

    /// One poll. Returns whether it asked for a redraw.
    @discardableResult
    func poll() -> Bool {
        guard running else { return false }
        let generation = levels.generation
        let interval = Self.interval(slow: slow, quietFor: quietFor)
        guard generation != lastGeneration else {
            quietFor += interval
            if interval == Self.liveInterval, quietFor >= Self.idleAfter { schedule() }
            return false
        }
        lastGeneration = generation
        let wasQuiet = quietFor >= Self.idleAfter
        quietFor = 0
        drawCount += 1
        frame += 1
        if wasQuiet { schedule() }
        return true
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval(slow: slow, quietFor: quietFor), repeats: true) { [weak self] _ in
            // The timer is added to the main run loop, so this closure always runs on the main thread.
            MainActor.assumeIsolated { _ = self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }
}

/// Reports whether the hosting window is on screen, so the meter stops while the panel is ordered out or covered.
private struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onChange) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        private let onChange: (Bool) -> Void
        init(_ onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            NotificationCenter.default.removeObserver(self)
            guard let window else { return onChange(false) }
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            changed()
        }

        @objc private func changed() { onChange(window?.occlusionState.contains(.visible) ?? false) }
    }
}

/// A row of dots. Each dot swells with the level it shows, and the newest level is on the right.
private struct DotMeter: View {
    let levels: LevelBuffer
    let accent: Color
    let paused: Bool
    let reduceMotion: Bool
    @StateObject private var driver: DotMeterDriver

    private static let count = 11
    private static let pitch: CGFloat = 8

    init(levels: LevelBuffer, accent: Color, paused: Bool, reduceMotion: Bool) {
        self.levels = levels
        self.accent = accent
        self.paused = paused
        self.reduceMotion = reduceMotion
        _driver = StateObject(wrappedValue: DotMeterDriver(levels: levels, slow: paused || reduceMotion))
    }

    var body: some View {
        dots(frame: driver.frame)
            .drawingGroup()
            .background(WindowVisibility { driver.setVisible($0) })
            .onChange(of: paused || reduceMotion) { _, slow in driver.setSlow(slow) }
    }

    private func dots(frame: Int) -> some View {
        Canvas { context, size in
            _ = frame
            let (bars, _) = levels.recent(Self.count)
            let padded = Array(repeating: Float(0), count: max(0, Self.count - bars.count)) + bars
            let width = CGFloat(Self.count - 1) * Self.pitch
            let startX = (size.width - width) / 2
            for (index, level) in padded.suffix(Self.count).enumerated() {
                let amount = paused ? 0 : CGFloat(min(1, max(0, level)))
                let diameter = 3 + 3 * amount
                let rect = CGRect(x: startX + CGFloat(index) * Self.pitch - diameter / 2, y: size.height / 2 - diameter / 2,
                                  width: diameter, height: diameter)
                context.fill(Path(ellipseIn: rect), with: .color(accent.opacity(0.45 + 0.55 * Double(amount))))
            }
        }
        .accessibilityHidden(true)
    }
}
