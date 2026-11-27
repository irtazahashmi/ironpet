import Foundation

/// Loudness samples for the waveform. The audio thread records peaks; the main thread calls `tick` at a fixed rate to
/// turn them into evenly spaced bars. Views read it on their own timer or timeline, so drawing never goes through
/// `@Published` and never re-renders the chat.
public final class LevelBuffer: @unchecked Sendable {
    public init() {}

    public static let tickInterval: TimeInterval = 1.0 / 25
    private static let capacity = 400

    private let lock = NSLock()
    private var peak: Float = 0
    private var bars: [Float] = []
    private var previous: Float = 0
    private var lastTick: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var changes = 0

    /// Counts the ticks that produced a bar different from the one before, plus each reset. It only grows. A view that
    /// polls it can skip a redraw when the number has not moved, as during silence.
    public var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }

    /// Called from the audio thread.
    public func record(_ level: Float) {
        lock.lock()
        peak = max(peak, level)
        lock.unlock()
    }

    /// Closes the current interval into one bar. A fast attack and slow release keep the bars from flickering.
    public func tick() {
        lock.lock()
        let bar = max(peak, previous * 0.7)
        previous = bar
        peak = 0
        if bar != (bars.last ?? 0) { changes += 1 }
        bars.append(bar)
        if bars.count > Self.capacity { bars.removeFirst(bars.count - Self.capacity) }
        lastTick = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// The newest `count` bars, oldest first, padded with silence on the left, and how far through the current
    /// interval it is (0...1) so the view can scroll smoothly between ticks.
    public func recent(_ count: Int) -> (bars: [Float], phase: Double) {
        lock.lock()
        defer { lock.unlock() }
        let tail = Array(bars.suffix(count))
        let padded = [Float](repeating: 0, count: max(0, count - tail.count)) + tail
        return (padded, min(1, (ProcessInfo.processInfo.systemUptime - lastTick) / Self.tickInterval))
    }

    public func reset() {
        lock.lock()
        peak = 0
        previous = 0
        bars = []
        changes += 1
        lastTick = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }
}
