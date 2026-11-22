# ironpet JSON-RPC contract

This document is the contract between IronPetCore and every client of it: the Mac window, the iPhone app, the CLI, and any
out-of-process client. Tests in `Tests/IronPetCoreTests/Contract/` check it against the code, so a method, an event or an error
that the code has and this page lacks fails the build.

Data crosses the boundary, not behaviour. A call takes one plain `Codable` value and returns one, or fails with an `APIError`.
JSON-RPC 2.0 carries those values unchanged.

## Transports

The message format is the same on every transport. Only the framing differs.

| Transport | Who uses it | Framing |
|---|---|---|
| stdio | Local clients that start the host as a child process | Newline-delimited JSON. One message per line, UTF-8, `\n` ends it. A message never contains a raw newline, because JSON escapes it. |
| HTTP | Remote clients | Each method maps to the `/v1` route in its row below. The route's own body and status codes apply, as described in "Differences between RPC and REST". |
| WebSocket | Remote clients that want events | `GET /v1/events` streams the events below. |

Status: the method table and the envelope exist in core PR 11 (`RPCDispatcher` and `JSONRPCRequest` and its siblings in IronPetKit).
Core PR 12 adds the session handshake and serves it on the remote event socket. The stdio host executable comes later, and no other method is
served over a transport yet.

## Envelope

Every message is a JSON-RPC 2.0 object. `jsonrpc` is always `"2.0"`.

```json
{"jsonrpc":"2.0","id":1,"method":"tasks.get","params":{"id":"3F2A..."}}
{"jsonrpc":"2.0","id":1,"result":{"task":{},"history":[]}}
{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"no task with id \"3F2A...\"","data":{"code":"not_found"}}}
{"jsonrpc":"2.0","method":"tasks.changed","params":{"seq":12,"at":"2026-11-06T21:20:00Z"}}
```

- `id` is a number or a string that the client picks. The response repeats it. A response to a line that could not be read has `"id": null`.
- A method that returns nothing sends `"result": null`. A response has `result` or `error`, never both.
- Keys come out sorted. Dates are ISO 8601 UTC strings with no fractional seconds, such as `2026-11-06T21:20:00Z`. Enums are their raw string, except `AgentStatus`, which is its number.
- `params` is the `Codable` request value. The decoder wants every field that is not optional, so a request type with fields like `includeDone` needs them in `params` even when they are `false`. An omitted optional field means "not given".
- Methods are named `<facade>.<method>`, with the lowerCamel facade property of `IronPetAPI` and the Swift method name.

## Handshake

Implemented in core PR 12. `session.hello` is the first request on a connection:

```json
{"jsonrpc":"2.0","id":1,"method":"session.hello","params":{
  "protocol":1,
  "client":{"name":"ironpet-ios","version":"1.4.0"},
  "lastSeq":120}}
```

| Field | Meaning |
|---|---|
| `protocol` | The contract version the client speaks. This document is version 1. |
| `client.name`, `client.version` | Who is calling, for the access log. |
| `lastSeq` | Optional. The last event `seq` the client saw, so the host can say whether it missed any. |

The result:

```json
{"jsonrpc":"2.0","id":1,"result":{
  "protocol":1,
  "server":{"name":"IronPetCore","version":"1.4.0"},
  "session":"b1c0...",
  "capabilities":["agents","alerts","automations","bubbles","chat","meetings","notifications","session","settings","tasks","today"],
  "seq":130,
  "gap":false}}
```

`capabilities` lists the facades this host serves, in name order. It is not what the client can do for the host (see "Clients and capabilities").
`memory` and `screen` appear once the host has attached them. `seq` is the newest event number. `gap` is true when the host no longer held every event
after `lastSeq`, so the client must read each area again. Without `lastSeq`, `gap` is false.

A `protocol` the host does not speak fails with `invalid` and `data: {"code": "invalid", "supported": [1]}`. A failed hello opens no session.

### Over the remote event socket

`GET /v1/events` is the connection of a paired phone. The host opens a session when the WebSocket upgrades, with the device's id and name and the
kind `ios`, and ends it when the socket closes, whatever the reason. The phone may then send `session.hello` as a text frame, and gets the
JSON-RPC response as a text frame between the events. The hello names the program in the session it already has, so it does not open a second
one. A phone that never sends it still has a session and still gets the frames it got before. The socket takes no other method: any other
request gets `Method not found`, and a frame longer than 16 KiB closes the socket.

### Over stdio

A host with no session of its own opens one when it gets `session.hello`. The stdio host executable comes after core PR 12, so no stdio client
exists yet.

## Clients and capabilities

Each connected client has a `ClientSession`, a plain value:

| Field | Meaning |
|---|---|
| `id` | The session's own id, new for each connection. |
| `deviceID` | The paired device's id. The app that hosts the core is `local`. |
| `name` | The device's name. |
| `kind` | `mac`, `ios`, `cli` or `windows`. `mac` and `windows` are desktop clients. |
| `capabilities` | Sorted names of what the client does when the host asks. |
| `lastInputAt` | When the person last used the client's keyboard or mouse. Absent when the client does not say. |
| `connectedAt` | When the session started. |
| `subscriptions` | Event names the client wants. Empty means every event. |
| `connection` | `inProcess` for the hosting app, `remote` for a device on a socket. |
| `client` | The program and version from `session.hello`, once sent. |

The hosting Mac app is a session from launch, with kind `mac`. Its capabilities are one for each platform adapter that is real: `screen` for screen capture, `presence`
for idle and lock, `secrets`, `processes`, `log`, `appInfo`, `clock`, `meetings`, `speech`, `petAssets`, `files`, `openURL` and `audio`, plus `desktop` once the desktop tools exist. An adapter
that is `Unsupported` adds nothing. A paired iPhone is a session of kind `ios` with no capabilities, for as long as its event socket is open.

The host sends its own requests to clients through `CapabilityRouter`, and only to a client that advertises the capability. With none connected it fails with
`unsupported` (-32006), naming the capability and the platform. Which client gets the request:

1. A client of the chat turn's origin device that advertises the capability. `ChatOrigin` carries the device id as `device`.
2. Otherwise the desktop client that advertises it and was active most recently, by `lastInputAt`, else by `connectedAt`.
3. Otherwise, or when two desktop clients are equally recent, the router returns the candidates and sends nothing. The caller asks the user which one they mean.
   Nothing is guessed.

"My screen" is this rule with the `screen` capability. A phone has none, so a chat turn from a phone means the most recent desktop.

The idle time that automations and the welcome-back summary read is the most recent `lastInputAt` of any desktop client. Lock, wake and microphone state stay with the machine they
describe.

## Errors

A failed call returns `error` with `code`, `message` and `data`. `message` is for a person. A client branches on `code`.

| JSON-RPC code | Name | When | `data` |
|---|---|---|---|
| -32700 | Parse error | The line is not JSON. `id` is `null`. | none |
| -32600 | Invalid request | The line is JSON but not a request, or `jsonrpc` is not `"2.0"`. | none |
| -32601 | Method not found | No such method. | `{"method": "<name>"}` |
| -32602 | Invalid params | `params` does not decode as the request type. | `{"field": "<path>"}`, such as `title` or `links[0].url` |
| -32001 | `not_found` | The id in the request names nothing. | `{"code": "not_found"}` |
| -32002 | `invalid` | A field is missing, out of range or not allowed. | `{"code": "invalid"}` |
| -32003 | `conflict` | The request is valid but the current state refuses it. | `{"code": "conflict"}` |
| -32004 | `unavailable` | The part of the app that serves the call is off, missing a permission or not running. | `{"code": "unavailable"}` |
| -32005 | `failed` | Anything else. A store error that is not an `APIError` also lands here. | `{"code": "failed"}` |
| -32006 | `unsupported` | No connected client advertises the capability the call needs, such as a screenshot when only a phone is connected. | `{"code": "unsupported", "capability": "<name>", "platform": "<name>"}` |

The six codes from -32001 to -32006 are `APIError.Code`. The REST routes answer `unsupported` with status 501. `data.code` repeats the `APIError` name, which is the string the Swift API and the REST
routes use. An `error` for a call that failed in Swift has the same `message` as the `APIError` the Swift caller sees.

## Events

The host sends one notification for each `APIEvent`. The method is the event name. A notification has no `id` and gets no answer.

```json
{"jsonrpc":"2.0","method":"chat.item","params":{"seq":412,"at":"2026-11-06T21:20:00Z","id":"7C0D..."}}
```

`params` holds `seq`, `at`, and `id` when one thing changed. An event carries no text of the user's. The client reads the area again with
the method in the last column. `seq` counts up from 1 for the life of the app. The host keeps the last 500 events, and keeps only the newest `chat.item` and `chat.state`
event for each id.

| Notification | Sent when | Read again with |
|---|---|---|
| `tasks.changed` | A task changed. | `tasks.list`, or `tasks.get` with `id` |
| `suggestions.changed` | A suggestion was added or removed. | `tasks.suggestions` |
| `chat.item` | One chat message was added or changed. `id` is the message. | `chat.messages` |
| `chat.state` | The chat's running state, queue, approvals, forms or draft changed. | `chat.status`, `chat.snapshot` |
| `agents.changed` | An agent session started, changed or ended. | `agents.list` |
| `alerts.changed` | An alert was added or dismissed. | `alerts.list` |
| `bubble.shown` | The pet shows a bubble. `id` is the bubble. | `bubbles.list` |
| `bubble.dismissed` | A bubble went away. | `bubbles.list` |
| `notifications.changed` | The notification log changed. | `notifications.list` |
| `automations.changed` | An automation was added, changed or removed. | `automations.list` |
| `automation.needsApproval` | An automation waits for Approve. `id` is the automation. No buttons are sent. | `automations.get`, then `automations.approve` or `automations.reject` |
| `meetings.changed` | A meeting was recorded, changed or deleted. | `meetings.list` |
| `settings.changed` | `config.json` changed. | `settings.get` |
| `pet.mood` | The pet's mood or badge changed. | `pet.state` (not yet on the wire, `GET /v1/pet`) |
| `assets.changed` | A pet sheet or background changed. | `pet.manifest` (not yet on the wire, `GET /v1/assets/manifest`) |

Over HTTP the same events arrive as JSON objects with `seq`, `at`, `kind` and `id` on the WebSocket at `GET /v1/events`.

## Methods

One section per public facade of `IronPetAPI`. A row is a method a client can call now. Types are the Swift types in `Sources/IronPetCore/API`,
encoded as JSON with the rules in "Envelope".

### `tasks`

Tasks and the suggestions that wait to become tasks.

| Method | Params | Result | REST route |
|---|---|---|---|
| `tasks.accept` | `AcceptSuggestionRequest` | `TaskItem` | `POST /v1/suggestions/:id/accept` |
| `tasks.acceptAll` | none | `null` | none |
| `tasks.close` | `CloseTaskRequest` | `TaskItem` | `POST /v1/tasks/:id/close` |
| `tasks.create` | `CreateTaskRequest` | `TaskItem` | `POST /v1/tasks` |
| `tasks.delete` | `DeleteTaskRequest` | `null` | `DELETE /v1/tasks/:id` |
| `tasks.get` | `ID` | `TaskWithHistory` | `GET /v1/tasks/:id` |
| `tasks.list` | `TaskListRequest` | `[TaskItem]` | `GET /v1/tasks` |
| `tasks.reject` | `RejectSuggestionRequest` | `null` | `POST /v1/suggestions/:id/reject` |
| `tasks.skip` | `ID` | `null` | none |
| `tasks.suggest` | `SuggestTaskRequest` | `[TaskSuggestion]` | none |
| `tasks.suggestions` | none | `[TaskSuggestion]` | `GET /v1/suggestions` |
| `tasks.update` | `UpdateTaskRequest` | `TaskItem` | `PATCH /v1/tasks/:id` |

`tasks.suggest` and `tasks.acceptAll` have no REST route because the phone does not create suggestions or accept them all. `tasks.skip` has none because REST has no skip.

### `alerts`

Open items that deserve a look, such as a failed CI run.

| Method | Params | Result | REST route |
|---|---|---|---|
| `alerts.ask` | `ID` | `null` | `POST /v1/alerts/:id/ask` |
| `alerts.dismiss` | `ID` | `null` | `POST /v1/alerts/:id/dismiss` |
| `alerts.dismissAll` | none | `null` | `POST /v1/alerts/dismiss-all` |
| `alerts.get` | `ID` | `Signal` | none |
| `alerts.list` | none | `[Signal]` | `GET /v1/alerts` |

`alerts.ask` fails with `unavailable` until the host sets the facade's `askHandler`. The in-process host sets it when the chat is open.

### `agents`

Coding-agent sessions ironpet watches.

| Method | Params | Result | REST route |
|---|---|---|---|
| `agents.acknowledge` | `ID` | `null` | `POST /v1/agents/:id/acknowledge` |
| `agents.acknowledgeAll` | none | `null` | none |
| `agents.ask` | `ID` | `null` | `POST /v1/agents/:id/ask` |
| `agents.get` | `ID` | `AgentSession` | `GET /v1/agents/:id` |
| `agents.list` | none | `[AgentSession]` | `GET /v1/agents` |

`agents.focus` is not on the wire. It needs a window on the Mac that runs the host, so it stays in Swift.

`status` is the raw number of `AgentStatus` (0 idle, 1 running, 2 done, 3 failed, 4 needs input, as the Swift enum orders them).

### `automations`

Reminders, watchers and scheduled jobs.

| Method | Params | Result | REST route |
|---|---|---|---|
| `automations.approve` | `ID` | `null` | none |
| `automations.create` | `CreateAutomationRequest` | `Automation` | `POST /v1/automations` |
| `automations.delete` | `ID` | `null` | `DELETE /v1/automations/:id` |
| `automations.get` | `ID` | `Automation` | `GET /v1/automations/:id` |
| `automations.history` | `AutomationHistoryRequest` | `[AutomationRunInfo]` | `GET /v1/automations/:id/history` |
| `automations.list` | none | `[Automation]` | `GET /v1/automations` |
| `automations.logs` | `AutomationLogRequest` | `[AutomationLogEntry]` | `GET /v1/automations/:id/log` |
| `automations.reject` | `ID` | `null` | none |
| `automations.runNow` | `ID` | `AutomationRunResult` | `POST /v1/automations/:id/run-now` |
| `automations.setEnabled` | `SetEnabled` | `null` | `POST /v1/automations/:id/pause`, `POST /v1/automations/:id/resume` |
| `automations.setSchedule` | `SetAutomationScheduleRequest` | `null` | none |
| `automations.status` | `ID` | `AutomationStatus` | none |
| `automations.update` | `UpdateAutomationRequest` | `Automation` | `PATCH /v1/automations/:id` |

`automations.setEnabled` takes `{"id", "enabled"}`. REST has two routes for it, pause and resume. `definition` and `changes` are JSON documents inside a string, as in Swift.

### `chat`

The open chat with Ghost.

| Method | Params | Result | REST route |
|---|---|---|---|
| `chat.answerForm` | `AnswerFormRequest` | `null` | `POST /v1/chat/forms/:id` |
| `chat.decide` | `DecideApprovalRequest` | `null` | `POST /v1/chat/approvals/:id` |
| `chat.messages` | none | `[ChatItem]` | none |
| `chat.newChat` | none | `null` | `POST /v1/chat/new` |
| `chat.openThread` | `ID` | `null` | `POST /v1/chat/open/:id` |
| `chat.send` | `SendChatRequest` | `ChatSendResult` | `POST /v1/chat/current/messages` |
| `chat.setMode` | `SetMode` | `null` | none |
| `chat.skipForm` | `UUIDParam` | `null` | `POST /v1/chat/forms/:id/skip` |
| `chat.snapshot` | none | `ChatSnapshot` | `GET /v1/chat/current` |
| `chat.status` | none | `ChatStatus` | none |
| `chat.stop` | none | `ChatStopResult` | `POST /v1/chat/current/stop` |
| `chat.submitForm` | `UUIDParam` | `null` | `POST /v1/chat/forms/:id/submit` |
| `chat.threads` | none | `[ChatThreadInfo]` | `GET /v1/chat/threads` |

`origin` is `{"client", "ref", "device"}`. `client` is the kind of sender such as `ios` or `telegram`, `ref` is its own id for the conversation, and `device` is the paired device's id when there is one. "My screen" in the turn means that device's screen (see "Clients and capabilities"). `chat.send` with an empty text and no `origin` returns `{"outcome": "ignored"}`. With an `origin` it fails with `invalid`. `chat.thread` returns a tuple in Swift, so it is not on the wire yet.

### `memory`

Ghost's notes and search over past chats, meetings and the screen.

| Method | Params | Result | REST route |
|---|---|---|---|
| `memory.call` | `MemoryCall` | `JSON` | none |

`memory.call` runs one `memory_*` tool. `params` is `{"name", "arguments", "caller"}` where `name` is `memory_remember`, `memory_forget`, `memory_search` or `memory_get`, and `arguments` is that tool's input object. The result is the tool's JSON output. A failure of the tool is `invalid` with the tool's message. It fails with `unavailable` until the host attaches the memory services.

### `settings`

`config.json`.

| Method | Params | Result | REST route |
|---|---|---|---|
| `settings.get` | none | `Config` | `GET /v1/settings` |
| `settings.patch` | `PatchSettingsRequest` | `Config` | `PATCH /v1/settings` |

`settings.patch` takes `{"patch": "<JSON merge patch as a string>"}`, as the Swift type does. It checks the whole patch before it changes anything.

### `today`

The morning brief and the evening recap.

| Method | Params | Result | REST route |
|---|---|---|---|
| `today.brief` | `BriefRequest` | `Brief` | `GET /v1/today` |

`kind` is `brief` or `recap`. `weekdays` and `day` are optional.

### `session`

The handshake, and the clients connected to the host.

| Method | Params | Result | REST route |
|---|---|---|---|
| `session.hello` | `HelloRequest` | `HelloResult` | none |

`HelloRequest` and `HelloResult` are the objects in "Handshake", with `protocol` for the version. It needs a connection, so a transport with none gets `unavailable`.

### `bubbles`

The speech bubbles the pet shows.

| Method | Params | Result | REST route |
|---|---|---|---|
| `bubbles.dismiss` | `ID` | `null` | none |
| `bubbles.list` | none | `[BubbleInfo]` | `GET /v1/bubbles` |

`bubbles.press` is not on the wire yet.

### `notifications`

The notification log.

| Method | Params | Result | REST route |
|---|---|---|---|
| `notifications.get` | `ID` | `NotificationItem` | none |
| `notifications.list` | `ListNotificationsRequest` | `NotificationList` | none |
| `notifications.markAllRead` | none | `null` | none |
| `notifications.markRead` | `ID` | `null` | none |

### `meetings`

Recorded meetings.

| Method | Params | Result | REST route |
|---|---|---|---|
| `meetings.delete` | `ID` | `null` | `DELETE /v1/meetings/:id` |
| `meetings.get` | `ID` | `MeetingInfo` | none |
| `meetings.list` | none | `[MeetingInfo]` | `GET /v1/meetings` |
| `meetings.stop` | none | `null` | `POST /v1/meetings/stop` |

The other `MeetingsAPI` methods are not on the wire yet (see below).

`meetings.stop` fails with `conflict` when no meeting is being recorded.

### `assistant`

`AssistantAPI.callTool(_:_:fromVoice:)` runs the assistant's tools. Its arguments and result are `[String: Any]` and `Result<Any, JobError>`, and the tools are the MCP tools of the Mac app.

Not yet on the wire. The assistant tools are reached through the local MCP endpoint.

### `desktop`

`DesktopAPI.callTool`, `openURL(_:browser:)`, `press(ref:)` and `key(app:key:)` drive other apps on the Mac. The tool call returns `DesktopOutput`, which can hold an image.

Not yet on the wire. A call acts on the host Mac only. Core PR 12 adds the capability routing a remote client needs (see "Clients and capabilities"), but a desktop request
does not use it yet.

### `pet`

`PetAPI.state()` returns `PetState` (`mood`, `badge`). Also `tricks()`, `perform(_:)`, `pets()`, `selectPet(_:)`, `backgroundList()`, `selectBackground(_:)`, `manifest()` and `assetData(_:)`.

Not yet on the wire. The requests and results are Codable, but the asset calls return `Data`, which JSON-RPC would carry as base64, and REST serves it as bytes (`GET /v1/assets/:sha256`). The REST routes `GET /v1/pet`, `POST /v1/pet/tricks/:name`, `GET /v1/settings/pets`, `POST /v1/settings/pet` and `GET /v1/assets/manifest` serve it today.

### `screen`

`ScreenAPI.status`, `recent(limit:)`, `search(_:)`, `captureText(_:)`, `pause(for:)`, `resume()` and `clear()` read and control screen capture. `callTool` is the MCP form.

| Method | Params | Result | REST route |
|---|---|---|---|
| `screen.ingest` | `ScreenIngestRequest` | `ScreenIngestResult` | none |

The reading methods are not yet on the wire. `status` and `seenApps()` return types that are not Codable. The REST routes `GET /v1/screen/status`, `/changes`, `/captures/:id`, `/search` and `POST /v1/screen/pause` serve them today.

`screen.ingest` stores captures that a client took on its own screen. `params` is `{"captures": [...]}`, at most 50 of them. A capture is `app` (bundle id or package name),
`appName`, `trigger` (a capture trigger such as `app_switch` or `idle`), `lines`, `redacted`, and optionally `title`, `url`, `inputLines` and `at`. Redaction stays on the
client: a capture with `redacted: false` fails with `invalid`, and the host cannot check that the client did it. The host still runs its own redactor over what it
stores, and applies pause and the app deny lists as it does for its own captures. The result counts `stored`, `unchanged` and `skipped` captures. It fails with `unavailable` until
the host attaches screen capture, and with `unsupported` when the host's capture adapter stores nothing.
The remote event socket does not serve it, because a device's `screen` scope allows reading captures, not writing them.

### `usage`

`UsageAPI.summary(_:)` takes `UsageRequest` (`days`, `hourly`) and returns `UsageSummary`. It exists only when the host created a `UsageStore`.

Not yet on the wire. Served by `GET /v1/usage`.

### `voice`

`VoiceAPI.status` returns `VoiceStatus`. `speak(_:)` and `preview(_:)` read text aloud on the Mac. `audio(_:)` returns an `AsyncThrowingStream` of audio chunks, and `transcribe(_:)` takes recorded audio.

Not yet on the wire. Audio does not fit a request and response, so it has its own WebSocket at `GET /v1/voice`.

## Differences between RPC and REST

A method and its REST route do the same thing, but the two bodies are not the same JSON yet.

- RPC results and params are the in-process `Codable` values of IronPetCore, with camelCase keys (`includeDone`, `sourceRef`).
- REST bodies are the IronPetKit types that the iOS app decodes (`RemoteTask`, `RemoteSuggestion` and the others), with the snake_case keys the Kit declares (`source_ref`). Core PR 10 moved the task and resource routes onto them.
- REST reports a failure with an HTTP status and `{"error": {"code", "message"}}`. RPC reports it as `error` above. The `code` string is the same `APIError` name in both.

Neither side changes in core PR 11. The conformance tests pin the RPC side only.

## REST routes

Every route `RemoteServer` registers, and the method that serves the same call. Routes with no method are about pairing, devices, uploads,
audio, or an area that is not on the wire yet.

| Route | RPC method |
|---|---|
| `POST /v1/pair` | none |
| `GET /v1/pair/:id` | none |
| `GET /v1/devices/me` | none |
| `DELETE /v1/devices/me` | none |
| `GET /v1/events` | none |
| `GET /v1/voice` | none |
| `GET /v1/tasks` | `tasks.list` |
| `POST /v1/tasks` | `tasks.create` |
| `GET /v1/tasks/:id` | `tasks.get` |
| `PATCH /v1/tasks/:id` | `tasks.update` |
| `POST /v1/tasks/:id/close` | `tasks.close` |
| `DELETE /v1/tasks/:id` | `tasks.delete` |
| `GET /v1/suggestions` | `tasks.suggestions` |
| `POST /v1/suggestions/:id/accept` | `tasks.accept` |
| `POST /v1/suggestions/:id/reject` | `tasks.reject` |
| `GET /v1/screen/status` | none |
| `GET /v1/screen/changes` | none |
| `GET /v1/screen/captures/:id` | none |
| `GET /v1/screen/search` | none |
| `POST /v1/screen/pause` | none |
| `GET /v1/automations` | `automations.list` |
| `POST /v1/automations` | `automations.create` |
| `POST /v1/automations/request` | none |
| `GET /v1/automations/:id` | `automations.get` |
| `PATCH /v1/automations/:id` | `automations.update` |
| `DELETE /v1/automations/:id` | `automations.delete` |
| `GET /v1/automations/:id/history` | `automations.history` |
| `GET /v1/automations/:id/log` | `automations.logs` |
| `POST /v1/automations/:id/pause` | `automations.setEnabled` |
| `POST /v1/automations/:id/resume` | `automations.setEnabled` |
| `POST /v1/automations/:id/run-now` | `automations.runNow` |
| `GET /v1/meetings` | `meetings.list` |
| `GET /v1/meetings/state` | none |
| `POST /v1/meetings/stop` | `meetings.stop` |
| `GET /v1/meetings/:id/summary` | none |
| `GET /v1/meetings/:id/transcript` | none |
| `POST /v1/meetings/:id/regenerate` | none |
| `POST /v1/meetings/:id/ask` | none |
| `DELETE /v1/meetings/:id` | `meetings.delete` |
| `GET /v1/settings` | `settings.get` |
| `PATCH /v1/settings` | `settings.patch` |
| `GET /v1/settings/pets` | none |
| `POST /v1/settings/pet` | none |
| `GET /v1/usage` | none |
| `GET /v1/chat/current` | `chat.snapshot` |
| `GET /v1/chat/messages/:id` | none |
| `GET /v1/chat/messages/:id/file` | none |
| `GET /v1/files/preview` | none |
| `GET /v1/chat/threads` | `chat.threads` |
| `GET /v1/chat/threads/:id` | none |
| `POST /v1/chat/current/messages` | `chat.send` |
| `POST /v1/chat/current/stop` | `chat.stop` |
| `POST /v1/chat/open/:id` | `chat.openThread` |
| `POST /v1/chat/new` | `chat.newChat` |
| `PATCH /v1/chat/options` | `chat.setAgent`, `chat.setModel`, `chat.useFolder`, `chat.useNoProject`, `chat.setMode` |
| `POST /v1/chat/approvals/:id` | `chat.decide` |
| `POST /v1/chat/forms/:id` | `chat.answerForm` |
| `POST /v1/chat/forms/:id/submit` | `chat.submitForm` |
| `POST /v1/chat/forms/:id/skip` | `chat.skipForm` |
| `POST /v1/uploads` | none |
| `GET /v1/pet` | none |
| `POST /v1/pet/tricks/:name` | none |
| `GET /v1/bubbles` | `bubbles.list` |
| `POST /v1/bubbles/:id/actions/:action` | none |
| `GET /v1/agents` | `agents.list` |
| `GET /v1/agents/:id` | `agents.get` |
| `POST /v1/agents/:id/acknowledge` | `agents.acknowledge` |
| `POST /v1/agents/:id/ask` | `agents.ask` |
| `GET /v1/alerts` | `alerts.list` |
| `POST /v1/alerts/dismiss-all` | `alerts.dismissAll` |
| `POST /v1/alerts/:id/dismiss` | `alerts.dismiss` |
| `POST /v1/alerts/:id/ask` | `alerts.ask` |
| `GET /v1/today` | `today.brief` |
| `GET /v1/assets/manifest` | none |
| `GET /v1/assets/:sha256` | none |
| `GET /v1/events` | none |
| `GET /v1/voice` | none |

## Conformance tests

`swift test --filter Contract` runs these checks, on macOS and on Linux.

- `ContractGoldenTests` sends each request in `Tests/IronPetCoreTests/Contract/Fixtures/*.json` through `RPCDispatcher.handle(line:)` against an `IronPetAPI` built on in-memory stores,
  and compares the response with the golden one. Keys are sorted. Ids a request captured become `$name`, other UUIDs `<uuid>`, times `<date>`, and temp folders `<tmp>`.
  A mismatch names the method and the field, such as `tasks.create (create): response.result.title: the golden file has this field and the API does not`.
- `ContractErrorTests` covers the error shapes that no method raises with in-memory stores, and the envelope.
- `ContractDocTests` fails when this page lacks an event, an `APIError` case, a facade, a method, or a `/v1` route.

After a deliberate API change, run `UPDATE_GOLDENS=1 swift test --filter ContractGoldenTests`, read the diff of the fixtures, and update this page.
