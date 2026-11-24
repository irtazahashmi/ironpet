import AppKit
import XCTest
@testable import IronPet
@testable import IronPetCore

/// Prints open, append and scroll cost on a 5,000-item transcript. Numbers only, no thresholds beyond a loose ceiling.
@MainActor
final class TranscriptPerfTests: XCTestCase {
    override func setUpWithError() throws { try CISkip.unlessLocal() }

    private func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    func testOpenAppendAndScrollCostOnAHugeTranscript() throws {
        let session = ChatSession(restore: false)
        let long = (0..<5).map { "Sentence \($0) of a reply that wraps across several lines in the chat column." }.joined(separator: " ")
        var thread: [ChatSession.Item] = []
        var i = 0
        while thread.count < 5000 {
            thread.append(.init(kind: .user("Question \(i)")))
            thread.append(.init(kind: .tool("Ran `step \(i)`", ok: true)))
            thread.append(.init(kind: .assistant(i % 2 == 0 ? long + "\n\n" + long : "Short answer \(i)")))
            i += 1
        }
        session.items = thread
        let panel = IronPetPanel.chat(session)
        panel.setContentSize(CGSize(width: 520, height: 640))
        let openStart = Date(), openCPU = HugeTranscriptTests.threadCPU()
        panel.orderFrontRegardless()
        spin(3)
        print("PERF open: wall \(String(format: "%.2f", Date().timeIntervalSince(openStart))) s (includes 3 s idle), cpu \(String(format: "%.2f", HugeTranscriptTests.threadCPU() - openCPU)) s, footprint \(HugeTranscriptTests.footprintMB()) MB")

        // Append: each append is followed by the time the main thread needs before it is idle again.
        var appendCPU = 0.0, appendWorst = 0.0
        for i in 0..<20 {
            let cpu = HugeTranscriptTests.threadCPU()
            session.items.append(.init(kind: .tool("Ran `bench \(i)`", ok: true)))
            spin(0.25)
            let used = HugeTranscriptTests.threadCPU() - cpu
            appendCPU += used
            appendWorst = max(appendWorst, used)
        }
        print("PERF append: mean cpu \(String(format: "%.3f", appendCPU / 20)) s, worst \(String(format: "%.3f", appendWorst)) s over 20 appends")

        // Scroll from the end to the top with wheel events.
        let scroll = try XCTUnwrap(HugeTranscriptTests.scrollView(in: panel.contentView))
        let scrollStart = Date(), scrollCPU = HugeTranscriptTests.threadCPU()
        var steps = 0
        for _ in 0..<38 {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 600, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { break }
            scroll.scrollWheel(with: event)
            spin(0.016)
            steps += 1
        }
        spin(1)
        let doc = try XCTUnwrap(scroll.documentView)
        print("PERF scroll up 38 steps: \(steps) steps, wall \(String(format: "%.2f", Date().timeIntervalSince(scrollStart))) s, cpu \(String(format: "%.2f", HugeTranscriptTests.threadCPU() - scrollCPU)) s, content \(Int(doc.bounds.height)) pt, offset \(Int(scroll.contentView.bounds.minY))")
        panel.close()
    }
}
