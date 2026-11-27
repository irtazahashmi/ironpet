import Foundation
import IronPetKit
import QuickJS
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs a dashboard's script and turns what it builds into a tree of native components.
///
/// A dashboard is a script in the shape of a Herdr mod: it default-exports a view built from IronPet's components and reacts to
/// clicks.
///
/// ```js
/// import { Column, Stat, Button } from "ironpet";
/// export default {
///   view(ctx) {                       // ctx.data is the dashboard's saved state
///     return Column([
///       Stat({ label: "Inbox", value: String(ironpet.inbox().length) }),
///       Button({ label: "Ask the pet", onClick: () => ironpet.prompt("What is in my inbox?") }),
///     ]);
///   },
///   count(ctx) { return ironpet.inbox().length; },   // optional: the number on the sidebar icon
/// };
/// ```
///
/// The script is not trusted. It runs in a fresh QuickJS context for each render and each click, with no `fetch`, files, processes,
/// timers or modules. Everything it can reach goes through `ironpet.*`, and each call checks the capabilities the user approved:
/// - `ironpet.run(cmd, args)` needs `run:<command line prefix>`, and runs without a shell.
/// - `ironpet.fetch(url, options)` needs `network:<host>`.
/// - `ironpet.inbox()`, `alerts()` and `agents()` need `read:<name>`; `ironpet.inboxDone(id)` and `inboxRemove(id)` need `write:inbox`.
/// - `ironpet.prompt(text)` needs `prompt`.
/// - `ironpet.setData(patch)`, `open(url)`, `openFile(path)` and `openChat()` need nothing. The last three act only on a click.
/// A call that is not approved throws, and the script's error is shown on the dashboard. Nothing undeclared runs.
package enum DashboardRuntime {
    package static let memoryLimit = 32 * 1024 * 1024
    package static let maxHostCalls = 30
    package static let maxEffects = 10
    package static let maxScriptBytes = DashboardValidator.maxScriptBytes
    package static let maxTreeBytes = 512 * 1024
    package static let maxFetchBytes = 1024 * 1024
    package static let renderDeadline: TimeInterval = 15
    package static let clickDeadline: TimeInterval = 45

    package struct Failure: Error, LocalizedError, Equatable {
        package init(message: String) { self.message = message }
        package let message: String
        package var errorDescription: String? { message }
    }

    /// What a click asks the host to do after the script returned. Only `prompt` and `open*` exist; data changes are in `patch`.
    package struct Effect: Equatable {
        package init(kind: String, value: String? = nil) {
            self.kind = kind
            self.value = value
        }

        /// `prompt`, `open` (a link), `file` or `chat`.
        package var kind: String
        package var value: String?
    }

    package struct Rendered: Equatable {
        package var root: DashboardNode
        /// What the script's `count` returned, when it has one.
        package var count: Int?
        package var logs: [String]
    }

    package struct Clicked {
        /// Keys to set on the saved state. A null value removes the key.
        package var patch: [String: Any]
        package var effects: [Effect]
        package var logs: [String]
    }

    /// What the host gives a script. Replaced in tests.
    package struct Host {
        package init(run: @escaping (_ command: String, _ args: [String], _ timeout: TimeInterval) -> CommandResult = { _, _, _ in CommandResult(spawnError: "not available") },
                     fetch: @escaping (_ url: URL, _ method: String, _ headers: [String: String], _ body: String?, _ timeout: TimeInterval) -> FetchResult = { _, _, _, _, _ in FetchResult(error: "not available") },
                     read: @escaping (_ name: String) -> Any = { _ in [] },
                     write: @escaping (_ op: String, _ id: String) -> String? = { _, _ in "not available" }) {
            self.run = run
            self.fetch = fetch
            self.read = read
            self.write = write
        }

        package var run: (_ command: String, _ args: [String], _ timeout: TimeInterval) -> CommandResult
        package var fetch: (_ url: URL, _ method: String, _ headers: [String: String], _ body: String?, _ timeout: TimeInterval) -> FetchResult
        /// The JSON-compatible value of `inbox`, `alerts` or `agents`.
        package var read: (_ name: String) -> Any
        /// `inboxDone` or `inboxRemove` on an item. Returns a problem, or nil when it worked.
        package var write: (_ op: String, _ id: String) -> String?

        /// Runs commands for real, with no shell: `/usr/bin/env <command> <args>`.
        package static func system(spawner: ProcessSpawner, read: @escaping (String) -> Any, write: @escaping (String, String) -> String?) -> Host {
            Host(run: { command, args, timeout in
                CommandRunner.runBlocking(executable: "/usr/bin/env", arguments: [command] + args, spawner: spawner, timeout: timeout,
                                          environment: CommandRunner.defaultEnvironment(), stdin: nil, maxBytes: CommandRunner.maxOutput)
            }, fetch: { url, method, headers, body, timeout in
                DashboardRuntime.fetchBlocking(url: url, method: method, headers: headers, body: body, timeout: timeout)
            }, read: read, write: write)
        }
    }

    package struct FetchResult: Equatable {
        package init(status: Int? = nil, body: String = "", truncated: Bool = false, error: String? = nil) {
            self.status = status
            self.body = body
            self.truncated = truncated
            self.error = error
        }

        package var status: Int?
        package var body: String
        package var truncated: Bool
        package var error: String?
    }

    // MARK: Entry points

    /// Builds the view from `data`. `allowed` is the set of capability tokens the user approved.
    package static func render(script: String, data: [String: Any], allowed: Set<String>, host: Host,
                               deadline: TimeInterval = renderDeadline) async throws -> Rendered {
        try await onScriptThread { try renderBlocking(script: script, data: data, allowed: allowed, host: host, deadline: deadline) }
    }

    /// Builds the view again, then runs the handler `handler` the view named, and returns what it asked for.
    package static func click(script: String, data: [String: Any], allowed: Set<String>, host: Host, handler: String,
                              deadline: TimeInterval = clickDeadline) async throws -> Clicked {
        try await onScriptThread { try clickBlocking(script: script, data: data, allowed: allowed, host: host, handler: handler, deadline: deadline) }
    }

    /// Checks that the script parses and has a default export with a `view`. Nothing else runs.
    package static func check(_ script: String) -> String? {
        do {
            return try onScriptStackSync {
                let sandbox = try Sandbox(script: script, data: [:], allowed: [], host: Host(), deadline: 2, effectsEnabled: false)
                _ = sandbox
                return nil as String?
            }
        } catch {
            return error.localizedDescription
        }
    }

    package static func renderBlocking(script: String, data: [String: Any], allowed: Set<String>, host: Host, deadline: TimeInterval) throws -> Rendered {
        let sandbox = try Sandbox(script: script, data: data, allowed: allowed, host: host, deadline: deadline, effectsEnabled: false)
        let text = try sandbox.evaluate("__render()")
        guard text.utf8.count <= maxTreeBytes else { throw Failure(message: "the view is larger than \(maxTreeBytes / 1024) KiB") }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let tree = object["tree"] else {
            throw Failure(message: "the view returned something that is not a component")
        }
        let treeData = try JSONSerialization.data(withJSONObject: tree)
        guard let root = try? JSONDecoder().decode(DashboardNode.self, from: treeData) else {
            throw Failure(message: "the view returned something that is not a component")
        }
        let reported = (object["count"] as? Double).flatMap { $0.isFinite ? Int($0) : nil }
        return Rendered(root: root, count: reported, logs: sandbox.logs)
    }

    package static func clickBlocking(script: String, data: [String: Any], allowed: Set<String>, host: Host, handler: String, deadline: TimeInterval) throws -> Clicked {
        // The view runs first, as it does for a render, with no effects and no inbox changes. Only the handler may act.
        let sandbox = try Sandbox(script: script, data: data, allowed: allowed, host: host, deadline: deadline, effectsEnabled: false)
        _ = try sandbox.evaluate("__render()")
        sandbox.enableEffects()
        _ = try sandbox.evaluate("(__effects.length = 0, __patch = {}, 'ok')")
        let text = try sandbox.evaluate("__click(\(jsonStringLiteral(handler)))")
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { throw Failure(message: "the handler returned nothing") }
        let patch = object["patch"] as? [String: Any] ?? [:]
        let effects = ((object["effects"] as? [[String: Any]]) ?? []).prefix(maxEffects).compactMap { entry -> Effect? in
            guard let kind = entry["kind"] as? String else { return nil }
            return Effect(kind: kind, value: entry["value"] as? String)
        }
        return Clicked(patch: patch, effects: Array(effects), logs: sandbox.logs)
    }

    // MARK: Threads

    /// QuickJS limits recursion to 1 MiB below the stack pointer of the thread that made the runtime, and Swift concurrency threads
    /// have less, so every runtime lives on a thread with a larger stack.
    private static let stackBytes = 8 * 1024 * 1024

    private static func onScriptThread<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
            thread.stackSize = stackBytes
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private static func onScriptStackSync<T>(_ body: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result { try body() }
            done.signal()
        }
        thread.stackSize = stackBytes
        thread.start()
        done.wait()
        return try result!.get()
    }

    private static func jsonStringLiteral(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    // MARK: Capability checks

    /// Whether `commandLine` is covered by an approved `run:` token: equal to its command line, or continuing it after a space.
    package static func runAllowed(_ commandLine: String, by allowed: Set<String>) -> Bool {
        allowed.contains { token in
            guard token.hasPrefix("run:") else { return false }
            let prefix = String(token.dropFirst(4))
            return commandLine == prefix || commandLine.hasPrefix(prefix + " ")
        }
    }

    package static func networkAllowed(host: String, by allowed: Set<String>) -> Bool { allowed.contains("network:\(host.lowercased())") }

    /// A script's `open` target: only http and https links.
    package static func isWebLink(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    private static func fetchBlocking(url: URL, method: String, headers: [String: String], body: String?, timeout: TimeInterval) -> FetchResult {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = Data(body.utf8) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // A redirect to another host would get around the approved host list, so only same-host redirects are followed.
        let session = URLSession(configuration: configuration, delegate: SameHostRedirects(), delegateQueue: nil)
        let done = DispatchSemaphore(value: 0)
        // Written by the completion handler, read only after `done` is signalled or the wait times out, and then the session is cancelled.
        nonisolated(unsafe) var result = FetchResult(error: "no answer")
        session.dataTask(with: request) { data, response, error in
            if let error { result = FetchResult(error: error.localizedDescription) } else {
                let bytes = data ?? Data()
                let capped = bytes.prefix(maxFetchBytes)
                result = FetchResult(status: (response as? HTTPURLResponse)?.statusCode, body: String(decoding: capped, as: UTF8.self), truncated: bytes.count > maxFetchBytes)
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        session.invalidateAndCancel()
        return result
    }

    private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable { // No state: safe to share.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let from = task.originalRequest?.url?.host?.lowercased()
            completionHandler(from != nil && request.url?.host?.lowercased() == from ? request : nil)
        }
    }

    // MARK: Sandbox

    private final class Sandbox {
        private let runtime: JSRuntime
        private let context: JSContext
        private let started = Date()
        private let limit: TimeInterval
        private var calls = 0
        private let allowed: Set<String>
        private let host: Host
        private var effectsEnabled: Bool
        private(set) var logs: [String] = []

        init(script: String, data: [String: Any], allowed: Set<String>, host: Host, deadline: TimeInterval, effectsEnabled: Bool) throws {
            guard script.utf8.count <= DashboardRuntime.maxScriptBytes else {
                throw Failure(message: "the script is longer than \(DashboardRuntime.maxScriptBytes / 1024) KiB")
            }
            limit = deadline
            self.allowed = allowed
            self.host = host
            self.effectsEnabled = effectsEnabled
            let started = self.started
            var options = JSRuntimeOptions(memoryLimit: DashboardRuntime.memoryLimit, enableStdModules: false, enableHelpers: false,
                                           interruptHandler: { Date().timeIntervalSince(started) > deadline }, flushJobsAfterEval: true)
            options.enableStdModules = false
            guard let runtime = JSRuntime(options: options), let context = runtime.createContext() else {
                throw Failure(message: "could not start the script engine")
            }
            self.runtime = runtime
            self.context = context
            installHost()
            try evaluateSource(Self.prelude, type: .module, name: "prelude.js")
            let dataText = (try? JSONSerialization.data(withJSONObject: data)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            try evaluateSource("globalThis.__data = JSON.parse(\(DashboardRuntime.jsonStringLiteral(dataText)));", type: .global, name: "prelude.js")
            try evaluateSource(Self.rewrite(script), type: .global, name: "main.js")
            let kind = try evaluate("__shape()")
            if kind != "ok" { throw Failure(message: kind) }
        }

        func enableEffects() { effectsEnabled = true }

        private var remaining: TimeInterval { max(1, limit - Date().timeIntervalSince(started)) }

        /// The script's `export default` becomes an assignment, and an `import ... from "ironpet"` line is dropped: the components are
        /// globals. A script is one file with no other modules.
        static func rewrite(_ script: String) -> String {
            var lines = script.components(separatedBy: "\n")
            var exported = false
            for index in lines.indices {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("import "), trimmed.contains("\"ironpet\"") || trimmed.contains("'ironpet'") {
                    lines[index] = ""
                } else if !exported, let range = lines[index].range(of: "export default") {
                    lines[index].replaceSubrange(range, with: "globalThis.__default =")
                    exported = true
                } else if trimmed.hasPrefix("export "), let range = lines[index].range(of: "export ") {
                    lines[index].removeSubrange(range)
                }
            }
            return lines.joined(separator: "\n")
        }

        private func installHost() {
            func arg(_ context: JSContext, _ argc: Int, _ argv: UnsafeMutablePointer<JSCValue>?, _ index: Int) -> String? {
                guard let argv, index < argc else { return nil }
                return String(context, value: argv[index])
            }
            context.module("host") {
                JSModuleFunction("call", argc: 2) { [unowned self] context, _, argc, argv in
                    guard let name = arg(context, argc, argv, 0) else { return JSError.exception("call needs a name") }
                    let json = arg(context, argc, argv, 1) ?? "null"
                    let argument = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) ?? NSNull()
                    return self.reply(self.handle(name, argument))
                }
                JSModuleFunction("log", argc: 1) { [unowned self] context, _, argc, argv in
                    if self.logs.joined().utf8.count < 4096, let line = arg(context, argc, argv, 0) { self.logs.append(String(line.prefix(500))) }
                    return nil
                }
            }
        }

        private func reply(_ result: Result<Any, Failure>) -> String {
            let object: [String: Any]
            switch result {
            case .success(let value): object = ["ok": true, "value": value]
            case .failure(let failure): object = ["ok": false, "error": failure.message]
            }
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data("{\"ok\":false,\"error\":\"bad reply\"}".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        /// One host call from the script. Everything that reaches outside the sandbox is decided here.
        private func handle(_ name: String, _ argument: Any) -> Result<Any, Failure> {
            calls += 1
            guard calls <= DashboardRuntime.maxHostCalls else { return .failure(Failure(message: "too many host calls in one run (\(DashboardRuntime.maxHostCalls))")) }
            let object = argument as? [String: Any] ?? [:]
            switch name {
            case "run":
                guard let command = object["command"] as? String, !command.isEmpty else { return .failure(Failure(message: "run needs a command")) }
                let args = (object["args"] as? [Any])?.map { "\($0)" } ?? []
                let line = ([command] + args).joined(separator: " ")
                guard DashboardRuntime.runAllowed(line, by: allowed) else {
                    return .failure(Failure(message: "the dashboard may not run \"\(line)\": it is not an approved command"))
                }
                let timeout = min(max(1, (object["timeoutSeconds"] as? Double) ?? 30), remaining)
                let result = host.run(command, args, timeout)
                return .success(["code": result.code.map { Int($0) } as Any? ?? NSNull(), "stdout": result.stdout, "stderr": result.stderr,
                                 "timedOut": result.timedOut, "truncated": result.truncated, "error": result.spawnError as Any? ?? NSNull()] as [String: Any])
            case "fetch":
                guard let text = object["url"] as? String, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", let hostName = url.host else { return .failure(Failure(message: "fetch needs an http or https URL")) }
                guard DashboardRuntime.networkAllowed(host: hostName, by: allowed) else {
                    return .failure(Failure(message: "the dashboard may not reach \(hostName): it is not an approved host"))
                }
                let method = ((object["method"] as? String) ?? "GET").uppercased()
                guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method) else { return .failure(Failure(message: "unsupported method \(method)")) }
                let headers = (object["headers"] as? [String: Any])?.mapValues { "\($0)" } ?? [:]
                let result = host.fetch(url, method, headers, object["body"] as? String, min(30, remaining))
                return .success(["status": result.status as Any? ?? NSNull(), "body": result.body, "truncated": result.truncated, "error": result.error as Any? ?? NSNull()] as [String: Any])
            case "read":
                guard let what = object["name"] as? String, DashboardCapabilities.readable.contains(what) else { return .failure(Failure(message: "read needs inbox, alerts or agents")) }
                guard allowed.contains("read:\(what)") else { return .failure(Failure(message: "the dashboard may not read \(what): it is not approved")) }
                return .success(host.read(what))
            case "inboxDone", "inboxRemove":
                guard allowed.contains("write:inbox") else { return .failure(Failure(message: "the dashboard may not change the inbox: it is not approved")) }
                guard effectsEnabled else { return .failure(Failure(message: "the inbox changes only when the user clicks")) }
                guard let id = object["id"] as? String, !id.isEmpty else { return .failure(Failure(message: "\(name) needs an id")) }
                if let problem = host.write(name, id) { return .failure(Failure(message: problem)) }
                return .success(true)
            case "prompt":
                guard allowed.contains("prompt") else { return .failure(Failure(message: "the dashboard may not prompt the pet: it is not approved")) }
                guard effectsEnabled else { return .failure(Failure(message: "a prompt is sent only when the user clicks")) }
                guard let text = object["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(Failure(message: "prompt needs text")) }
                return .success(true)
            case "open":
                guard effectsEnabled else { return .failure(Failure(message: "a link opens only when the user clicks")) }
                guard let text = object["url"] as? String, DashboardRuntime.isWebLink(text) else { return .failure(Failure(message: "open needs an http or https link")) }
                return .success(true)
            case "openFile":
                guard effectsEnabled else { return .failure(Failure(message: "a file opens only when the user clicks")) }
                guard let path = object["path"] as? String, path.hasPrefix("/") || path.hasPrefix("~") else { return .failure(Failure(message: "openFile needs an absolute path")) }
                return .success(true)
            case "openChat":
                guard effectsEnabled else { return .failure(Failure(message: "the chat opens only when the user clicks")) }
                return .success(true)
            default:
                return .failure(Failure(message: "unknown host call \(name)"))
            }
        }

        private func evaluateSource(_ source: String, type: JSContext.EvalType, name: String) throws {
            do { _ = try context.evaluate(source, options: EvalOptions(type: type, filename: name, strict: true)) }
            catch { throw Failure(message: Self.describe(error)) }
        }

        func evaluate(_ expression: String) throws -> String {
            do {
                let value = try context.evaluate(expression, options: EvalOptions(type: .global, filename: "main.js", strict: true))
                guard let text = value.string else { throw Failure(message: "the script returned no text") }
                return text
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure(message: Self.describe(error))
            }
        }

        private static func describe(_ error: Error) -> String {
            switch error as? JSError {
            case .interrupted?: return "the script ran too long and was stopped"
            case .exception(let message)?: return message.contains("interrupted") ? "the script ran too long and was stopped" : message
            case .conversionFailed?: return "the script returned a value that cannot be read"
            case nil: return error.localizedDescription
            }
        }

        /// The components and `ironpet`, as globals. A handler a component names is kept by its position in the view, so the same
        /// script and data give the same ids on the next run, which is how a click finds its handler in a fresh context.
        static let prelude = """
            import { call as __call, log as __log } from "host";
            const __host = (name, arg) => {
              const r = JSON.parse(__call(name, JSON.stringify(arg === undefined ? null : arg)));
              if (!r.ok) throw new Error(r.error);
              return r.value;
            };
            globalThis.__handlers = [];
            globalThis.__patch = {};
            globalThis.__effects = [];
            const __effect = (kind, value) => { __effects.push(value === undefined ? { kind } : { kind, value }); };
            globalThis.console = { log: (...a) => __log(a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')) };
            globalThis.ironpet = {
              get data() { return globalThis.__data; },
              setData(patch) {
                for (const k of Object.keys(patch || {})) { if (patch[k] === null) { delete __data[k]; } else { __data[k] = patch[k]; } __patch[k] = patch[k]; }
              },
              run(command, args, options) { return __host("run", { command, args: args || [], timeoutSeconds: options && options.timeoutSeconds }); },
              fetch(url, options) { const o = options || {}; return __host("fetch", { url, method: o.method, headers: o.headers, body: o.body }); },
              inbox() { return __host("read", { name: "inbox" }); },
              alerts() { return __host("read", { name: "alerts" }); },
              agents() { return __host("read", { name: "agents" }); },
              inboxDone(id) { return __host("inboxDone", { id }); },
              inboxRemove(id) { return __host("inboxRemove", { id }); },
              prompt(text) { __host("prompt", { text: String(text) }); __effect("prompt", String(text)); },
              open(url) { __host("open", { url: String(url) }); __effect("open", String(url)); },
              openFile(path) { __host("openFile", { path: String(path) }); __effect("file", String(path)); },
              openChat() { __host("openChat", {}); __effect("chat"); },
            };
            const __action = (onClick) => {
              if (onClick === undefined || onClick === null) return undefined;
              let fn = onClick;
              if (typeof onClick === 'object') {
                fn = () => {
                  if (onClick.prompt !== undefined) ironpet.prompt(onClick.prompt);
                  if (onClick.open !== undefined) ironpet.open(onClick.open);
                  if (onClick.file !== undefined) ironpet.openFile(onClick.file);
                  if (onClick.chat) ironpet.openChat();
                  if (onClick.setData !== undefined) ironpet.setData(onClick.setData);
                };
              }
              if (typeof fn !== 'function') return undefined;
              __handlers.push(fn);
              return "h" + (__handlers.length - 1);
            };
            const __str = (v) => (v === undefined || v === null) ? undefined : String(v);
            const __kids = (children) => (Array.isArray(children) ? children : [children]).filter(c => c !== undefined && c !== null && c !== false);
            globalThis.Column = (children, o) => ({ type: "column", tone: __str(o && o.tone), children: __kids(children) });
            globalThis.Row = (children, o) => ({ type: "row", children: __kids(children) });
            globalThis.Card = (o) => ({ type: "card", text: __str(o.title), caption: __str(o.caption), tone: __str(o.tone), badge: __str(o.badge), action: __action(o.onClick), children: __kids(o.children || []) });
            globalThis.Text = (text, o) => ({ type: "text", text: String(text), style: __str(o && o.style), tone: __str(o && o.tone) });
            globalThis.Heading = (text) => ({ type: "text", text: String(text), style: "heading" });
            globalThis.Stat = (o) => ({ type: "stat", label: __str(o.label), value: __str(o.value), caption: __str(o.caption), tone: __str(o.tone) });
            globalThis.List = (items) => ({ type: "list", children: (items || []).map(i => ({ type: "item", text: __str(i.title), caption: __str(i.caption), badge: __str(i.badge), tone: __str(i.tone), symbol: __str(i.symbol), action: __action(i.onClick) })) });
            globalThis.Table = (o) => ({ type: "table", columns: (o.columns || []).map(String), rows: (o.rows || []).map(r => r.map(String)) });
            globalThis.Chart = (o) => ({ type: "chart", text: __str(o.title), chart: o.kind === "bar" ? "bar" : "line", points: (o.points || []).map(Number), labels: o.labels ? o.labels.map(String) : undefined, tone: __str(o.tone) });
            globalThis.Button = (o) => ({ type: "button", label: __str(o.label), symbol: __str(o.symbol), tone: __str(o.tone), action: __action(o.onClick) });
            globalThis.Divider = () => ({ type: "divider" });
            globalThis.__shape = () => {
              const d = globalThis.__default;
              if (d === undefined) return "the script needs an export default: a function or an object with a view function";
              if (typeof d === "function" || (d && typeof d.view === "function")) return "ok";
              return "the default export must be a function or an object with a view function";
            };
            globalThis.__view = () => { const d = globalThis.__default; return typeof d === "function" ? d : d.view; };
            globalThis.__render = () => {
              __handlers.length = 0;
              const ctx = { data: __data };
              const tree = __view().call(__default, ctx);
              if (tree === undefined || tree === null || typeof tree !== "object") throw new Error("the view must return a component such as Column([...])");
              let count;
              if (typeof __default === "object" && __default.count !== undefined) {
                const c = typeof __default.count === "function" ? __default.count.call(__default, ctx) : __default.count;
                if (typeof c === "number" && isFinite(c)) count = c;
              }
              return JSON.stringify({ tree, count });
            };
            globalThis.__click = (id) => {
              const index = Number(String(id).slice(1));
              const fn = __handlers[index];
              if (typeof fn !== "function") throw new Error("this button no longer exists");
              fn();
              return JSON.stringify({ patch: __patch, effects: __effects });
            };
            """
    }
}
