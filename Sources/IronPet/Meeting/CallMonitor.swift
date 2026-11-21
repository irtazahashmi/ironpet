import CoreAudio
import Foundation
import IronPetCore

/// Polls Core Audio for processes capturing input, without ever calling it on the main thread.
///
/// Every Core Audio read is a round trip to coreaudiod, which can stall for seconds. The reads run on a private serial
/// queue. A poll is skipped while the previous one is still running. A read slower than `slowThreshold` makes the next
/// polls wait, with the wait doubling up to `maxBackoff`, and is logged once per slow streak.
@MainActor
final class CallMonitor {
    let detector: CallDetector
    private let query: @Sendable () -> [MicClient]
    private let uptime: () -> TimeInterval
    private let interval: TimeInterval
    private let slowThreshold: TimeInterval
    private let maxBackoff: TimeInterval
    private let queue = DispatchQueue(label: "ironpet.call-monitor", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var backoff: TimeInterval = 0
    private var notBefore: TimeInterval = 0
    private var snapshot: [MicClient] = []
    private var loggedSlow = false
    /// Called on the main actor after each finished read. Tests use it to wait.
    var onPolled: (() -> Void)?

    init(detector: CallDetector, interval: TimeInterval = 2, slowThreshold: TimeInterval = 2, maxBackoff: TimeInterval = 60,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         query: @escaping @Sendable () -> [MicClient] = CoreAudioReader().read) {
        self.detector = detector
        self.interval = interval
        self.slowThreshold = slowThreshold
        self.maxBackoff = maxBackoff
        self.uptime = uptime
        self.query = query
        // The detector reads the last snapshot, so its own tick never touches Core Audio.
        detector.source = { [unowned self] in snapshot }
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        detector.reset()
    }

    /// Starts one background read unless one is running or a backoff is in effect.
    func poll() {
        guard !inFlight, uptime() >= notBefore else { return }
        inFlight = true
        let started = uptime()
        let query = self.query
        queue.async { [weak self] in
            let result = query()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(result, started: started) }
            }
        }
    }

    private func finish(_ result: [MicClient], started: TimeInterval) {
        inFlight = false
        let took = uptime() - started
        if took > slowThreshold {
            backoff = min(max(backoff * 2, slowThreshold * 2), maxBackoff)
            notBefore = uptime() + backoff
            if !loggedSlow {
                loggedSlow = true
                NSLog("ironpet: Core Audio call query took %.1fs, backing off", took)
            }
        } else {
            backoff = 0
            notBefore = 0
            loggedSlow = false
        }
        snapshot = result
        detector.tick()
        onPolled?()
    }
}

/// Reads the process objects from Core Audio (macOS 14.2+). Only call `read` from one queue at a time.
/// A process object's PID and bundle ID never change, so they are read once and cached.
final class CoreAudioReader: @unchecked Sendable {
    private var identities: [AudioObjectID: MicClient] = [:]

    /// Every process object that currently has input running.
    func read() -> [MicClient] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        identities = identities.filter { objects.contains($0.key) }
        return objects.compactMap { object in
            guard Self.uint32(object, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            if let known = identities[object] { return known }
            guard let pid = Self.int32(object, kAudioProcessPropertyPID) else { return nil }
            let client = MicClient(pid: pid, bundleID: Self.string(object, kAudioProcessPropertyBundleID) ?? "")
            identities[object] = client
            return client
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var address = address(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
