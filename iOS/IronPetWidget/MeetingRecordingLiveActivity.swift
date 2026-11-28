import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Lock Screen and Dynamic Island view of a room recording: a timer that runs by itself and a Stop button.
struct MeetingRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingRecordingAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "record.circle").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording the room").font(.headline)
                    timer(context)
                }
                Spacer()
                stop(context)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) { timer(context).font(.title3) }
                DynamicIslandExpandedRegion(.bottom) { stop(context) }
            } compactLeading: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            } compactTrailing: {
                timer(context).frame(width: 52)
            } minimal: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
        }
    }

    private func timer(_ context: ActivityViewContext<MeetingRecordingAttributes>) -> some View {
        Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .accessibilityIdentifier("recording-activity-timer")
    }

    @ViewBuilder
    private func stop(_ context: ActivityViewContext<MeetingRecordingAttributes>) -> some View {
        if context.state.recording {
            Button(intent: StopMeetingRecordingIntent()) { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.borderedProminent).tint(.red)
        } else {
            Text("Saving").font(.caption).foregroundStyle(.secondary)
        }
    }
}
