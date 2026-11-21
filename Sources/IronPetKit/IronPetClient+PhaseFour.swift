import Foundation

/// The phase 4 calls: automations, meetings, settings, the pet gallery and usage.
extension IronPetClient {
    // MARK: Automations

    public func automations() async throws -> [RemoteAutomation] { try await get(AutomationListResponse.self, APIPath.automations).automations }

    public func automation(id: String) async throws -> RemoteAutomation { try await get(RemoteAutomation.self, APIPath.automation(id)) }

    public func automationHistory(id: String) async throws -> [RemoteAutomationRun] {
        try await get(AutomationHistoryResponse.self, APIPath.automationHistory(id)).history
    }

    public func automationLog(id: String) async throws -> [RemoteAutomationLogEntry] {
        try await get(AutomationLogResponse.self, APIPath.automationLog(id)).log
    }

    public func pauseAutomation(id: String) async throws { try await post(APIPath.pauseAutomation(id)) }

    public func resumeAutomation(id: String) async throws { try await post(APIPath.resumeAutomation(id)) }

    @discardableResult
    public func runAutomation(id: String) async throws -> RemoteAutomationRunResult {
        try await post(RemoteAutomationRunResult.self, APIPath.runAutomation(id))
    }

    public func deleteAutomation(id: String) async throws { _ = try await perform(request("DELETE", APIPath.automation(id))) }

    /// Makes an automation from its JSON definition. One that runs a command, script or prompt still waits for Approve on the Mac.
    @discardableResult
    public func createAutomation(definition: String) async throws -> RemoteAutomation {
        try await post(RemoteAutomation.self, APIPath.automations, json: try Self.object(definition))
    }

    /// Merges `changes` (a JSON object) into an automation. Changing what it runs makes it wait for Approve on the Mac again.
    @discardableResult
    public func updateAutomation(id: String, changes: String) async throws -> RemoteAutomation {
        let data = try JSONSerialization.data(withJSONObject: try Self.object(changes))
        return try decode(RemoteAutomation.self, from: try await perform(request("PATCH", APIPath.automation(id), body: data)))
    }

    /// Sends "New automation…" to the chat, where the agent builds it.
    public func requestAutomation(_ text: String) async throws { try await post(APIPath.requestAutomation, json: ["text": text]) }

    private static func object(_ json: String) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw ClientError.api(status: 400, code: "invalid", message: "That is not a JSON object.")
        }
        return object
    }

    // MARK: Meetings

    public func meetings() async throws -> [RemoteMeeting] { try await get(MeetingListResponse.self, APIPath.meetings).meetings }

    public func meetingState() async throws -> RemoteMeetingState { try await get(RemoteMeetingState.self, APIPath.meetingState) }

    public func meetingSummary(id: String) async throws -> String { try await get(RemoteMeetingText.self, APIPath.meetingSummary(id)).text }

    public func meetingTranscript(id: String) async throws -> String { try await get(RemoteMeetingText.self, APIPath.meetingTranscript(id)).text }

    /// Starts the rebuild and returns. `meetingState` says when it ends.
    public func regenerateMeeting(id: String, summaryOnly: Bool) async throws {
        _ = try await perform(request("POST", APIPath.regenerateMeeting(id), query: [URLQueryItem(name: "mode", value: summaryOnly ? "summary" : "full")],
                                      body: Data("{}".utf8)))
    }

    public func askAboutMeeting(id: String) async throws { try await post(APIPath.askAboutMeeting(id)) }

    public func deleteMeeting(id: String) async throws { _ = try await perform(request("DELETE", APIPath.meeting(id))) }

    public func stopMeeting() async throws { try await post(APIPath.stopMeeting) }

    // MARK: Settings

    public func settings() async throws -> RemoteConfig { try await get(RemoteConfig.self, APIPath.settings) }

    /// A JSON merge patch over the keys the phone may change, written with the names of `config.json`.
    @discardableResult
    public func patchSettings(_ patch: [String: Any]) async throws -> RemoteConfig {
        let data = try JSONSerialization.data(withJSONObject: patch)
        return try decode(RemoteConfig.self, from: try await perform(request("PATCH", APIPath.settings, body: data)))
    }

    public func pets() async throws -> [RemotePetChoice] { try await get(PetChoiceListResponse.self, APIPath.settingsPets).pets }

    public func selectPet(id: String) async throws { try await post(APIPath.settingsPet, json: ["id": id]) }

    public func usage(days: Int = 7) async throws -> RemoteUsage {
        try await get(RemoteUsage.self, APIPath.usage, query: [URLQueryItem(name: "range", value: "\(days)d")])
    }
}
