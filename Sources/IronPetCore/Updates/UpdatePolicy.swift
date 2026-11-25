import Foundation

/// The rules that decide whether the app may update itself and when it may restart. The Mac app feeds them what it sees and
/// follows the answer, so the rules run in tests without Sparkle or a window.
package enum UpdatePolicy {
    /// Why updates are off for this build, or nil when they are on. A build from `scripts/install.sh` carries `IronPetDevBuild`
    /// and is replaced by running the script again, so a release must never overwrite it. A debug override feed (a local appcast
    /// for testing) turns updates back on for that build only. A build without `SUPublicEDKey` could not verify an update's
    /// signature, so it stays off too.
    package static func disabledReason(version: AppVersion, overrideFeed: URL? = nil, hasPublicKey: Bool = true) -> String? {
        if version.isDev, overrideFeed == nil { return "Updates are off for dev builds. Run scripts/install.sh to update this one." }
        if !hasPublicKey { return "Updates are off: this build has no update signing key (SUPublicEDKey)." }
        return nil
    }

    /// What ironpet is doing that a restart would cut off.
    package struct Activity: Equatable {
        package var agentTurnRunning: Bool
        package var voiceRecording: Bool
        package var meetingRecording: Bool

        package init(agentTurnRunning: Bool = false, voiceRecording: Bool = false, meetingRecording: Bool = false) {
            self.agentTurnRunning = agentTurnRunning
            self.voiceRecording = voiceRecording
            self.meetingRecording = meetingRecording
        }
    }

    /// What a restart would interrupt, or nil when it is safe to restart. Shown in the badge's help text.
    package static func busyReason(_ activity: Activity) -> String? {
        if activity.meetingRecording { return "a meeting recording" }
        if activity.voiceRecording { return "a voice recording" }
        if activity.agentTurnRunning { return "an agent turn" }
        return nil
    }

    /// Whether an update that is downloaded and ready may install and restart the app now. An explicit click on the badge or the
    /// notification passes `userApproved`: that is the user choosing the moment, so it goes through even while busy.
    package static func mayInstallNow(_ activity: Activity, userApproved: Bool) -> Bool {
        userApproved || busyReason(activity) == nil
    }

    /// The downgrade guard. An update whose database schema is older than the one on this Mac would open a newer database and
    /// refuse it (`Database.refuseNewer`), leaving the user without their data until they reinstall. Returns the message to show
    /// when the update must be refused, or nil when it may install. An update that does not say its schema is let through:
    /// older appcasts did not carry the field, and the app's own check still protects the data.
    package static func downgradeRefusal(updateSchema: Int?, localSchema: Int, updateVersion: String) -> String? {
        guard let updateSchema, updateSchema < localSchema else { return nil }
        return "IronPet \(updateVersion) is older than the data on this Mac (its database is at version \(updateSchema), "
            + "yours is at \(localSchema)), so it was not installed. Your data is untouched."
    }
}
