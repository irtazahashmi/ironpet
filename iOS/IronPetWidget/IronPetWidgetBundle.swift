import SwiftUI
import WidgetKit

@main
struct IronPetWidgetBundle: WidgetBundle {
    var body: some Widget {
        PetStatusWidget()
        PetLiveActivity()
        MeetingRecordingLiveActivity()
    }
}
