import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The agent-facing side: the automation MCP tools (served by `MCPEndpoint` at `POST /mcp`), a plain endpoint for the
/// CLI (`POST /automations`), the CLI itself, and a stdio bridge so agents that only speak stdio MCP can use the tools.
/// All of them call `AutomationsAPI.callJSON`, which validates.
@MainActor
package enum AutomationMCP {
    package static let guide = """
        An automation is a reminder, watcher or scheduled job that ironpet's pet (Ghost) runs. Shape:
        {"name": "Stand up", "trigger": {...}, "action": {...}, "presentation": {...}}
        trigger.type is one of:
        - interval: {"type":"interval","minutes":45,"clock":"active"|"wall"}. "active" counts keyboard time only and resets after a break. "wall" is clock time.
        - daily: {"type":"daily","times":["09:00"],"weekdays":["mon","tue"],"catchUpMinutes":120}. weekdays is optional. catchUpMinutes (optional, 0 to 720): a slot missed while the Mac slept or ironpet was not running still fires when it is at most that many minutes late; 0 fires on time only.
        - once: {"type":"once","at":"2026-11-20T15:30:00+01:00"}. Turns itself off after it fires.
        - poll: {"type":"poll","minutes":5,"source":{"type":"shell","command":"gh pr list --json number,title"},"items":"[?draft==`false`]","id":"number","version":"updatedAt"}. items, id and version are JMESPath (id and version run on one item).
          Source is shell or http ({"type":"http","url":"...","headers":{"Authorization":"${TOKEN}"}}). Items come from the JMESPath expression in items, and filters like [?state=='open'] do the filtering. The first run only records what exists. After that each new id (or changed version) fires once.
        - stream: {"type":"stream","command":"...","mode":"lines"|"json","items"?,"id"?,"version"?,"when"?,"debounceSeconds"?,"throttleSeconds"?,"cooldownMinutes"?}. A command that keeps running and prints one event per line, such as fswatch, `log stream`, `tail -f` or `gh run watch`, with no polling. ironpet starts it when the automation is on, stops it (SIGTERM, then SIGKILL, on the whole process group) when it is paused, deleted, changed or ironpet quits, and restarts it after it exits, waiting 1 s, then 2 s and so on up to 5 min. Put --line-buffered on grep, sed or awk -W interactive in a pipeline so lines are not held back. mode "lines" (default) gives {{item.line}}. mode "json" reads one JSON value per line, with items, id and version as in poll (id and version dedupe; without id every event fires). when is a JMESPath filter on one item that must be truthy, such as contains(line, 'error') or level=='error'. debounceSeconds fires once after that long without a new event, with the latest one, and {{count}} is how many events it stands for. throttleSeconds allows at most one fire per that many seconds. While an action runs, only the newest waiting event is kept and it fires when the action ends. Lines over 64 KiB and more than 20 events a second are dropped and logged. stderr goes to the log. Example, a bubble for each new PDF in Downloads: {"name":"New PDFs","trigger":{"type":"stream","command":"fswatch --event Created ~/Downloads | grep --line-buffered '[.]pdf$'","debounceSeconds":2},"action":{"type":"bubble","title":"{{count}} new PDF(s)","body":"{{item.line}}"}}. automations_get shows "stream": "running"|"restarting"|"stopped" and "lastEvent".
        - script: {"type":"script","minutes":5,"script":"function poll(state) { ... return {state, actions}; }"}. For watchers that need to compare with the last run. A script automation has no action field: leave action out of automations_create (an action on a script trigger is rejected, and an empty one is ignored). poll(state) gets what it returned last time (null the first time). It may call sh(command, {timeoutSeconds}) (returns {code, stdout, stderr, timedOut}) at most 8 times, and console.log. For the network, run curl through sh, and read secrets with `security find-generic-password -w` or an environment variable, never as literals. It must be a plain function, not async. It returns {state: any JSON to keep, actions: [...]}. Each action has a type:
            {"type":"bubble","title","body"?,"id"?,"severity"?:"info|good|warn|bad","url"?,"symbol"?,"expiresSeconds"?,"notification"?}: a short-lived popup. Same id replaces it.
            {"type":"alert","id","title","subtitle"?,"label"?,"severity"?:"warn|bad|good|info","url"?,"ask"?,"version"?,"resolved"?}: an open item in the alerts list. A new or changed one also gets a bubble (the first run is quiet). Listed again unchanged, it is left alone even if the user dismissed it. "resolved": true removes it.
            {"type":"prompt","prompt","title"?,"agent"?,"model"?}: asks an agent in a background session and shows the answer.
            {"type":"suggest_task","id","title","due"?:"YYYY-MM-DD","notes"?,"url"?}: proposes a task (from an email, a message, an issue) as a suggestion the user adds or skips, never as a task. id is stable for the thing it is about; an id this automation suggested before is ignored, also after it was added or skipped. Title up to 200 characters, notes up to 2000, at most 10 per run. The first run is quiet; later runs show one bubble.
            {"type":"chat","text","title"?}: posts a system notice to the main chat, the same notice as a prompt with report "chat". text (up to 64 KiB) goes to the chat's agent once, inside a data-marked block, and starts a turn. A newer notice from this automation replaces one the agent has not read yet, so send one chat action per run.
          A script may also return {state, actions, done: true}: the automation deletes itself after its actions ran.
          It stops after 60 seconds or 32 MiB. No fetch, files, modules or timers.
        For the other triggers, action.type is one of: bubble {"title","body"}, prompt {"prompt","quiet"? (a string or a list),"session"? ("main" or "chat", "new", "own", "fork"),"report"? ("bubble" or "chat"),"allowedTools"?,"disallowedTools"?,"model"?} (by default, session "chat", sends the prompt into the user's open chat, where the chat's agent runs it with its full tools, memory and context; agent and model are ignored. session "new" runs it in a fresh agent session each time, session "own" resumes one thread for this automation (moves to a fresh agent session, with a handoff summary, when its transcript passes chat.sessionRolloverMB), and session "fork" starts from a copy of the main chat's agent session; all three have full tools minus disallowedTools (allowedTools lists tools that need no asking, model overrides the model), the prompt may be a slash skill such as "/am-check-emails 1", the run is listed in the thread list as an automation run, and a reply equal to quiet shows no bubble; report "chat" (the default for fork, and it makes session default to "new") posts the answer to the main chat as a system notice that the chat's agent reads and may act on, and an empty answer, NOTHING or NOTHING_NEW (or quiet) posts nothing; with an interval trigger it is a recurring loop; a prompt that uses {{item.*}} instead runs in a read-only background session and shows the answer in a bubble), shell {"command","timeoutSeconds"?,"report"? ("bubble" or "chat"),"quiet"?} (report "chat" posts the command, exit code and the last 4 KB of output to the main chat as a system notice that the chat's agent reads; a run that exits 0 starts a turn, a failure posts a notice without starting one, and exact output equal to quiet posts nothing), digest {"digest":"brief"|"recap"|"review"} (a bubble with what needs the user today, what happened today, or the weekly review: tasks, alerts, agents, meetings; built from data on this Mac with no agent; not for poll or stream triggers). The built-in morning-brief, day-recap and weekly-review automations use it and are off until the user turns them on.
        until (top-level, optional, not for script triggers): "success" deletes the automation after the first run whose action succeeded (a shell command that exits 0, a prompt that finished), after its report was posted. "once" deletes it after the first completed run, success or not. The run history stays readable through automations_history. Use it for a job that runs until something is true, such as a shell poll every few minutes with report "chat" and until "success" that exits 0 once a PR merged. A job that survives app and chat restarts.
        Text may use {{item.field}} (poll, stream), {{count}} (stream), {{name}} and {{now}}.
        presentation (optional): mood, symbol (SF Symbol), buttons (["done","snooze"]), notification (also a macOS notification).
        If the response to automations_create or automations_update has a note, tell the user what it says. Never put secrets in an automation: use $ENV_VAR references.
        """

    package static var tools: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required]]
        }
        let id: [String: Any] = ["id": ["type": "string", "description": "Automation id"]]
        return [
            tool("automations_list", "List every ironpet automation with its trigger, next run and last result.\n\n" + guide),
            tool("automations_get", "Get one automation in full (trigger, action with report and quiet, until), with its recent runs.", id, required: ["id"]),
            tool("automations_create", "Create an automation. Pass the fields at the top level (name, trigger, action, presentation). id is made from the name when missing.\n\n" + guide,
                 ["name": ["type": "string"], "id": ["type": "string"], "enabled": ["type": "boolean"], "trigger": ["type": "object"],
                  "action": ["type": "object"], "presentation": ["type": "object"], "note": ["type": "string"],
                  "until": ["type": "string", "enum": AutomationValidator.untilValues,
                            "description": "Delete the automation after a run: success (the action succeeded, such as exit 0) or once (the first completed run). Not for script triggers."]],
                 required: ["name", "trigger"]),
            tool("automations_update", "Change an automation. changes is merged into it; set a key to null to remove it.",
                 id.merging(["changes": ["type": "object"]]) { a, _ in a }, required: ["id", "changes"]),
            tool("automations_delete", "Delete an automation.", id, required: ["id"]),
            tool("automations_pause", "Turn an automation off without deleting it.", id, required: ["id"]),
            tool("automations_resume", "Turn a paused automation back on.", id, required: ["id"]),
            tool("automations_run_now", "Run an automation now, outside its schedule. Poll automations poll once.", id, required: ["id"]),
            tool("automations_history", "The last runs of an automation: time, outcome and short output.",
                 id.merging(["limit": ["type": "integer"]]) { a, _ in a }, required: ["id"]),
        ]
    }

    /// `POST /automations` with `{"op": "list", "args": {...}}`, for the CLI.
    package static func handleCLI(_ body: Data, api: AutomationsAPI) async -> (status: String, body: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let op = message["op"] as? String else {
            return ("400 Bad Request", MCPEndpoint.encode(["ok": false, "error": "send {\"op\": ..., \"args\": {...}}"]))
        }
        switch await api.callJSON(op, message["args"] as? [String: Any] ?? [:], by: "agent:cli") {
        case .success(let value): return ("200 OK", MCPEndpoint.encode(["ok": true, "result": value]))
        case .failure(let error): return ("200 OK", MCPEndpoint.encode(["ok": false, "error": error.message]))
        }
    }
}

/// `IronPet automations …` and `IronPet mcp`: run in a separate process, talking to the running app.
package enum AutomationCLI {
    package static let usage = """
        usage: IronPet automations <command>
          list                          all automations
          get <id>                      one automation in full
          add --name N --every MIN [--clock active|wall] [--title T] [--body B]
                                        a bubble reminder every MIN minutes
          add --name N --command CMD --every MIN [--report chat] [--until success|once]
                                        a shell job every MIN minutes (wall clock). --report chat posts the result to
                                        the main chat. --until deletes the automation after a run.
          add --json '<automation JSON>' | --file path.json
                                        a script trigger takes no action; the script returns its own
          update <id> --json '<changes JSON>'
          update <id> [--report bubble|chat] [--until success|once|none]
          pause <id> | resume <id> | delete <id> | run <id>
          history <id> [--limit N]
        The app must be running. Output is JSON.
        """

    /// Where the running app listens. Tests point it at their own server.
    package nonisolated(unsafe) static var endpoint: () -> (port: String, token: String)? = {
        guard let port = (try? String(contentsOf: Paths.portFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
              let token = (try? String(contentsOf: Paths.tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return (port, token)
    }

    /// Sends one request to the app. Returns nil when the app is not running.
    package static func post(path: String, body: Data, caller: String? = nil) -> (status: Int, body: Data)? {
        guard let (port, token) = endpoint(), let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(token, forHTTPHeaderField: "x-ironpet-token")
        if let caller { request.setValue(caller, forHTTPHeaderField: MCPEndpoint.callerHeader) }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Int, Data)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }

    /// Runs the command and returns the exit code, printing the result.
    package static func run(_ arguments: [String]) -> Int32 {
        let result = execute(arguments)
        if !result.out.isEmpty { print(result.out) }
        if !result.err.isEmpty { FileHandle.standardError.write(Data((result.err + "\n").utf8)) }
        return result.code
    }

    /// Runs the command and returns what it would print.
    package static func execute(_ arguments: [String]) -> (code: Int32, out: String, err: String) {
        var args = arguments
        guard let command = args.first else { return (2, usage, "") }
        if command == "help" || command == "--help" { return (0, usage, "") }
        args.removeFirst()
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let positional = args.first { !$0.hasPrefix("--") }
        var op = command
        var payload: [String: Any] = [:]
        switch command {
        case "list": break
        case "get", "pause", "resume", "delete", "history":
            guard let id = positional else { return fail("\(command) needs an id") }
            payload["id"] = id
            if command == "history", let limit = option("--limit").flatMap(Int.init) { payload["limit"] = limit }
        case "run":
            guard let id = positional else { return fail("run needs an id") }
            op = "run_now"
            payload["id"] = id
        case "update":
            guard let id = positional else { return fail("update needs an id and --json '{...}', --report or --until") }
            var changes: [String: Any] = [:]
            if let json = option("--json") {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return fail("that is not a JSON object") }
                changes = object
            }
            if let report = option("--report") {
                var action = changes["action"] as? [String: Any] ?? [:]
                action["report"] = report
                changes["action"] = action
            }
            if let until = option("--until") { changes["until"] = until == "none" ? NSNull() : until }
            guard !changes.isEmpty else { return fail("update needs an id and --json '{...}', --report or --until") }
            payload = ["id": id, "changes": changes]
        case "add", "create":
            op = "create"
            if let json = option("--json") ?? option("--file").flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }) {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return fail("that is not a JSON object") }
                payload = object
            } else {
                guard let name = option("--name"), let every = option("--every").flatMap(Double.init) else { return fail("add needs --name and --every, or --json") }
                if let command = option("--command") {
                    // A job, not a reminder: it runs on the clock, not on keyboard time.
                    var action: [String: Any] = ["type": "shell", "command": command]
                    if let report = option("--report") { action["report"] = report }
                    payload = ["name": name, "trigger": ["type": "interval", "minutes": every, "clock": option("--clock") ?? "wall"], "action": action]
                } else {
                    if option("--report") != nil { return fail("--report needs --command. A bubble reminder has no result to report") }
                    payload = ["name": name,
                               "trigger": ["type": "interval", "minutes": every, "clock": option("--clock") ?? "active"],
                               "action": ["type": "bubble", "title": option("--title") ?? name, "body": option("--body") ?? ""]]
                }
                if let until = option("--until") { payload["until"] = until }
            }
        default:
            return fail("unknown command \"\(command)\"")
        }
        return send(path: "/automations", op: op, args: payload)
    }

    /// Posts `{"op", "args"}` to a CLI endpoint and turns the answer into what the command prints.
    package static func send(path: String, op: String, args: [String: Any]) -> (code: Int32, out: String, err: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["op": op, "args": args])) ?? Data()
        guard let response = post(path: path, body: body) else { return fail("ironpet is not running") }
        guard response.status == 200, let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            return fail("the app answered \(response.status)")
        }
        if object["ok"] as? Bool == true, let result = object["result"],
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
            return (0, String(decoding: data, as: UTF8.self), "")
        }
        return fail(object["error"] as? String ?? "failed")
    }

    package static func fail(_ message: String) -> (code: Int32, out: String, err: String) {
        (1, "", "ironpet: \(message)")
    }

    /// MCP over stdio: each input line is a JSON-RPC message that goes to the app's `/mcp` endpoint.
    package static func stdioBridge(path: String = "/mcp") -> Int32 {
        // Set by the session that started this bridge when it is not the user's chat, such as an automation's own session.
        let caller = ProcessInfo.processInfo.environment[MCPEndpoint.callerVariable]
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let response = post(path: path, body: Data(line.utf8), caller: caller) else {
                if let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let id = message["id"] {
                    let error: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "ironpet is not running"]]
                    if let data = try? JSONSerialization.data(withJSONObject: error) { print(String(decoding: data, as: UTF8.self)) }
                }
                continue
            }
            if !response.body.isEmpty { print(String(decoding: response.body, as: UTF8.self)) }
            fflush(stdout)
        }
        return 0
    }
}
