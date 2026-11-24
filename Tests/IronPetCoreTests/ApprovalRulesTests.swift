import XCTest
@testable import IronPetCore

final class ApprovalRulesTests: XCTestCase {
    private func policy(_ call: ACPToolCall) -> ApprovalPolicy {
        ApprovalRules.policy(for: call)
    }

    private func shell(_ command: String, viaTitleOnly: Bool = false) -> ACPToolCall {
        viaTitleOnly ? ACPToolCall(id: "1", title: "`\(command)`", kind: "execute")
                     : ACPToolCall(id: "1", title: "Run", kind: "execute", rawInput: ["command": command])
    }

    func testEveryShellCommandAsksAndNoneIsJudgedByItsText() {
        XCTAssertEqual(policy(shell("ls .")), .ask(title: "Run this command?", detail: "ls ."))
        XCTAssertEqual(policy(shell("rm -rf /tmp/some-dir")), .ask(title: "Run this command?", detail: "rm -rf /tmp/some-dir"), "no destructive title: no pattern exists")
    }

    func testCommandIsReadFromTheTitleWhenTheAgentSendsNoArguments() {
        // Cursor's permission request has the command only in the title.
        XCTAssertEqual(policy(shell("touch a.txt", viaTitleOnly: true)), .ask(title: "Run this command?", detail: "touch a.txt"))
    }

    func testReadOnlyKindsAreAllowed() {
        for kind in ["read", "search", "think", "fetch"] {
            XCTAssertEqual(policy(ACPToolCall(id: "1", title: "x", kind: kind)), .allow, kind)
        }
    }

    func testEditsAndDeletesAsk() {
        // Memory lives in ironpet.db now, so no file the agent edits is ever a memory file.
        let edit = ACPToolCall(id: "1", title: "Edit", kind: "edit", rawInput: ["file_path": "/work/app.swift", "new_string": "let a = 1"])
        guard case .ask(let title, let detail) = policy(edit) else { return XCTFail("an edit asks") }
        XCTAssertEqual(title, "Edit app.swift?")
        XCTAssertTrue(detail.contains("/work/app.swift") && detail.contains("let a = 1"))
        for kind in ["edit", "delete", "move"] {
            if case .allow = policy(ACPToolCall(id: "3", title: kind, kind: kind, paths: ["/Users/you/.ironpet/memory/me.md"])) {
                XCTFail("\(kind) of a file asks, even under the old memory folder")
            }
        }
    }

    func testEditPathComesFromLocations() {
        var call = ACPToolCall(json: ["toolCallId": "9", "title": "Write", "kind": "edit", "locations": [["path": "/work/b.txt"]]])
        XCTAssertEqual(call.path, "/work/b.txt")
        call.merge(["toolCallId": "9", "status": "pending"])
        XCTAssertEqual(call.path, "/work/b.txt", "an update without locations keeps them")
    }

    func testMCPCallsAllowReadOnlyVerbsAndAskForTheRest() {
        let read = ACPToolCall(id: "1", title: "mcp__sentry__search_issues", kind: "other")
        XCTAssertEqual(policy(read), .allow)
        let write = ACPToolCall(id: "2", title: "mcp__db__run_query", kind: "other", rawInput: ["sql": "update t set a=1"])
        guard case .ask(let title, _) = policy(write) else { return XCTFail("a write tool asks") }
        XCTAssertEqual(title, "Use run_query (db)?")
    }

    func testQuickFilterToolsAllowedButDeleteAsks() {
        for tool in ["task_filters_list", "task_filters_upsert", "task_filters_reorder"] {
            XCTAssertEqual(policy(ACPToolCall(id: "1", title: "mcp__ironpet__\(tool)", kind: "other")), .allow, tool)
        }
        if case .allow = policy(ACPToolCall(id: "1", title: "mcp__ironpet__task_filters_delete", kind: "other")) { XCTFail("deleting a filter must ask") }
        if case .allow = policy(ACPToolCall(id: "1", title: "mcp__other__task_filters_upsert", kind: "other")) { XCTFail("another server must ask") }
    }

    func testOwnTaskWritesAllowedButDeleteAndOtherServersAsk() {
        for tool in ["tasks_create", "tasks_update", "tasks_close"] {
            XCTAssertEqual(policy(ACPToolCall(id: "1", title: "mcp__ironpet__\(tool)", kind: "other", rawInput: ["title": "x"])), .allow, tool)
            XCTAssertEqual(policy(ACPToolCall(id: "1", title: tool, kind: "other")), .allow, "bare \(tool)")
        }
        if case .allow = policy(ACPToolCall(id: "1", title: "mcp__ironpet__tasks_delete", kind: "other")) { XCTFail("delete must ask") }
        if case .allow = policy(ACPToolCall(id: "1", title: "mcp__other__tasks_create", kind: "other")) { XCTFail("another server must ask") }
        XCTAssertEqual(policy(ACPToolCall(id: "1", title: "mcp__ironpet__tasks_list", kind: "other")), .allow)
    }

    func testScreenToolsOfTheIronpetServerAreAllowedButOtherServersAsk() {
        for tool in ["screen_search", "screen_window"] {
            XCTAssertEqual(policy(ACPToolCall(id: "1", title: "mcp__ironpet__\(tool)", kind: "other")), .allow, tool)
            XCTAssertEqual(policy(ACPToolCall(id: "1", title: tool, kind: "other")), .allow, "bare \(tool)")
            if case .allow = policy(ACPToolCall(id: "1", title: "mcp__other__\(tool)", kind: "other")) { XCTFail("another server must ask") }
        }
    }

    func testAssistantReadsAndMemoryRunWithoutACardButJobControlAsks() {
        for tool in ["status_overview", "status_sessions", "jobs_list", "jobs_get", "jobs_open", "projects_resolve",
                     "memory_remember", "memory_forget", "memory_search", "memory_get"] {
            XCTAssertEqual(policy(ACPToolCall(id: "1", title: "mcp__ironpet__\(tool)", kind: "other", rawInput: ["text": "x"])), .allow, tool)
            if case .allow = policy(ACPToolCall(id: "1", title: "mcp__other__\(tool)", kind: "other")) { XCTFail("another server must ask: \(tool)") }
            if case .allow = policy(ACPToolCall(id: "1", title: tool, kind: "other")) { XCTFail("a bare \(tool) could be another server's") }
        }
        for tool in ["jobs_start", "jobs_followup", "jobs_stop"] {
            if case .allow = policy(ACPToolCall(id: "1", title: "mcp__ironpet__\(tool)", kind: "other", rawInput: ["id": "job-1"])) {
                XCTFail("\(tool) must ask")
            }
        }
    }

    func testMCPNameFromAgentMetadata() {
        let call = ACPToolCall(json: ["toolCallId": "1", "title": "Query", "kind": "other", "_meta": ["claudeCode": ["toolName": "mcp__langfuse__getHealth"]]])
        XCTAssertEqual(call.mcp?.server, "langfuse")
        XCTAssertEqual(policy(call), .allow)
    }

    func testPermissionOptionsMapToTheDecision() {
        let options: [JSON] = [["optionId": "a1", "kind": "allow_once"], ["optionId": "a2", "kind": "allow_always"],
                               ["optionId": "r1", "kind": "reject_once"]]
        func chosen(_ decision: ApprovalDecision, _ offered: [JSON]) -> String? {
            ((ACPBackend.outcome(decision, options: offered)["outcome"] as? JSON)?["optionId"]) as? String
        }
        XCTAssertEqual(chosen(.allow, options), "a1")
        XCTAssertEqual(chosen(.deny(), options), "r1")
        XCTAssertEqual(chosen(.allow, [["optionId": "x", "kind": "allow_always"]]), "x")
        XCTAssertNil(chosen(.deny(), [["optionId": "a1", "kind": "allow_once"]]), "no reject option offered means cancelled")
        XCTAssertEqual((ACPBackend.outcome(.deny(), options: [])["outcome"] as? JSON)?["outcome"] as? String, "cancelled")
    }

    func testToolSummaries() {
        XCTAssertEqual(shell("npm test").summary, "Ran `npm test`")
        XCTAssertEqual(ACPToolCall(id: "1", title: "", kind: "read", paths: ["/a/b/c.ts"]).summary, "Read c.ts")
        XCTAssertEqual(ACPToolCall(id: "1", title: "", kind: "edit", paths: ["/a/b/c.ts"]).summary, "Edited c.ts")
        XCTAssertEqual(ACPToolCall(id: "1", title: "Do the thing", kind: "other").summary, "Do the thing")
    }
}
