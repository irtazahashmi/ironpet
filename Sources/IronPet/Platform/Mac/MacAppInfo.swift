import Darwin
import Foundation

/// Finds the app that started an agent by walking its parent processes with `sysctl` and `proc_pidpath`.
struct MacAppInfo: AppInfo {
    init() {}

    func owningBundleID(pid: Int32) throws -> String? {
        Self.owningBundleID(pid: pid)
    }

    func displayName(bundleID: String) throws -> String? {
        guard let url = Self.appURL(bundleID: bundleID), let bundle = Bundle(url: url) else { return nil }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    /// Bundle id of the first ancestor (the process itself included) whose executable lives inside a `.app`.
    /// The lookups are injectable so tests don't need real processes.
    static func owningBundleID(
        pid: Int32,
        parent: (Int32) -> Int32? = realParent,
        executablePath: (Int32) -> String? = realPath,
        bundleID: (String) -> String? = realBundleID
    ) -> String? {
        var current = pid
        var seen = Set<Int32>()
        while current > 1, seen.insert(current).inserted {
            if let path = executablePath(current), let app = appBundlePath(in: path), let id = bundleID(app) { return id }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }

    /// `/Applications/Band.app` for `/Applications/Band.app/Contents/MacOS/Band`. The outermost `.app` wins, so a
    /// helper bundle nested inside an app reports the app.
    static func appBundlePath(in executable: String) -> String? {
        guard let range = executable.range(of: ".app/") else { return nil }
        return String(executable[..<range.lowerBound]) + ".app"
    }

    static func realParent(_ pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    static func realPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func realBundleID(_ appPath: String) -> String? {
        Bundle(path: appPath)?.bundleIdentifier
    }

    private static func appURL(bundleID: String) -> URL? {
        // The apps folders cover what ironpet needs a name for. Launch Services is AppKit's, and this file stays Foundation-only.
        for folder in ["/Applications", "/System/Applications", "\(NSHomeDirectory())/Applications"] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                if Bundle(url: url)?.bundleIdentifier == bundleID { return url }
            }
        }
        return nil
    }
}

extension Platform {
    /// The platform on a Mac, with every adapter real. `AppDelegate` builds it once. The meeting recorder and the speaker are the
    /// app's own objects. Screen capture needs the database, which opens later, so it starts `Unsupported` and `AppDelegate`
    /// replaces it once the service exists.
    @MainActor
    static func mac(meetings: MeetingRecorder, speech: SpeechOutput, capture: CaptureControl = UnsupportedCaptureControl()) -> Platform {
        Platform(secrets: KeychainSecretStore(), processes: POSIXProcessSpawner(), log: OSLogLog(),
                 appInfo: MacAppInfo(), clock: SystemClock(), meetings: meetings, capture: capture, speech: speech,
                 pets: MacPetAssets(), files: MacFileIntake())
    }
}
