import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct TelegramUser: Codable, Equatable {
    package init(id: Int64, isBot: Bool?, firstName: String?, lastName: String?, username: String?) {
        self.id = id
        self.isBot = isBot
        self.firstName = firstName
        self.lastName = lastName
        self.username = username
    }

    package let id: Int64
    package let isBot: Bool?
    package let firstName: String?
    package let lastName: String?
    package let username: String?

    package enum CodingKeys: String, CodingKey {
        case id, username
        case isBot = "is_bot"
        case firstName = "first_name"
        case lastName = "last_name"
    }

    package var displayName: String {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return full.isEmpty ? (username ?? String(id)) : full
    }
}

/// A file Telegram stores for a message: a photo size, document, voice message, audio, video or video note.
package struct TelegramAttachment: Codable, Equatable {
    package init(fileId: String, fileSize: Int? = nil, fileName: String? = nil, mimeType: String? = nil) {
        self.fileId = fileId
        self.fileSize = fileSize
        self.fileName = fileName
        self.mimeType = mimeType
    }

    package let fileId: String
    package var fileSize: Int?
    package var fileName: String?
    package var mimeType: String?

    package enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case fileSize = "file_size"
        case fileName = "file_name"
        case mimeType = "mime_type"
    }
}

package struct TelegramMessage: Codable, Equatable {
    package init(
        messageId: Int64,
        from: TelegramUser?,
        chat: Chat,
        text: String?,
        caption: String? = nil,
        photo: [TelegramAttachment]? = nil,
        document: TelegramAttachment? = nil,
        voice: TelegramAttachment? = nil,
        audio: TelegramAttachment? = nil,
        video: TelegramAttachment? = nil,
        videoNote: TelegramAttachment? = nil,
        mediaGroupId: String? = nil,
        replyToMessage: Original? = nil
    ) {
        self.messageId = messageId
        self.from = from
        self.chat = chat
        self.text = text
        self.caption = caption
        self.photo = photo
        self.document = document
        self.voice = voice
        self.audio = audio
        self.video = video
        self.videoNote = videoNote
        self.mediaGroupId = mediaGroupId
        self.replyToMessage = replyToMessage
    }

    /// The message this one replies to. Telegram nests it one level only, so the original has no reply of its own here.
    package struct Original: Codable, Equatable {
        package init(from: TelegramUser?, text: String?, caption: String? = nil, messageId: Int64? = nil) {
            self.from = from
            self.text = text
            self.caption = caption
            self.messageId = messageId
        }

        package let from: TelegramUser?
        package let text: String?
        package var caption: String? = nil
        /// Lets a reply be matched to the bot message it answers.
        package var messageId: Int64? = nil

        package enum CodingKeys: String, CodingKey {
            case from, text, caption
            case messageId = "message_id"
        }
    }

    package struct Chat: Codable, Equatable {
        package init(id: Int64, type: String) {
            self.id = id
            self.type = type
        }

        package let id: Int64
        package let type: String
    }

    package let messageId: Int64
    package let from: TelegramUser?
    package let chat: Chat
    package let text: String?
    package var caption: String? = nil
    /// The same photo in several sizes, smallest first.
    package var photo: [TelegramAttachment]? = nil
    package var document: TelegramAttachment? = nil
    package var voice: TelegramAttachment? = nil
    package var audio: TelegramAttachment? = nil
    package var video: TelegramAttachment? = nil
    package var videoNote: TelegramAttachment? = nil
    /// Photos or documents sent together as an album share this id.
    package var mediaGroupId: String? = nil
    /// Set when the user used Telegram's own Reply.
    package var replyToMessage: Original? = nil

    package enum CodingKeys: String, CodingKey {
        case from, chat, text, caption, photo, document, voice, audio, video
        case replyToMessage = "reply_to_message"
        case messageId = "message_id"
        case videoNote = "video_note"
        case mediaGroupId = "media_group_id"
    }
}

/// A tap on an inline keyboard button.
package struct TelegramCallback: Codable, Equatable {
    package init(id: String, from: TelegramUser, message: TelegramMessage? = nil, data: String? = nil) {
        self.id = id
        self.from = from
        self.message = message
        self.data = data
    }

    package let id: String
    package let from: TelegramUser
    package var message: TelegramMessage?
    package var data: String?
}

package struct TelegramUpdate: Codable, Equatable {
    package init(updateId: Int, message: TelegramMessage? = nil, callbackQuery: TelegramCallback? = nil) {
        self.updateId = updateId
        self.message = message
        self.callbackQuery = callbackQuery
    }

    package let updateId: Int
    package var message: TelegramMessage?
    package var callbackQuery: TelegramCallback? = nil

    package enum CodingKeys: String, CodingKey {
        case message
        case updateId = "update_id"
        case callbackQuery = "callback_query"
    }
}

/// Where Telegram keeps a file for download. `getFile` returns it.
package struct TelegramFilePath: Codable, Equatable {
    package init(filePath: String?, fileSize: Int? = nil) {
        self.filePath = filePath
        self.fileSize = fileSize
    }

    package let filePath: String?
    package var fileSize: Int?

    package enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case fileSize = "file_size"
    }
}

package struct TelegramButton: Equatable {
    package init(text: String, data: String) {
        self.text = text
        self.data = data
    }

    package let text: String
    package let data: String
}

package enum TelegramError: LocalizedError, Equatable {
    case noToken
    /// The Bot API answered `ok: false`.
    case api(code: Int, description: String)
    case network(String)

    package var errorDescription: String? {
        switch self {
        case .noToken: return "No bot token saved."
        case .api(401, _): return "Telegram rejected the bot token."
        case .api(409, _): return "Another program is polling this bot (409). Stop it, or use a different bot."
        case .api(let code, let description): return "Telegram error \(code): \(description)"
        case .network(let message): return "Network error: \(message)"
        }
    }
}

/// The part of the Bot API ironpet uses. The real one talks HTTPS; tests use a fake.
package protocol TelegramClient: Sendable {
    func getMe() async throws -> TelegramUser
    func getUpdates(offset: Int, timeout: Int) async throws -> [TelegramUpdate]
    /// `html` true sends `text` with parse mode HTML. `keyboard` is the inline keyboard, one array per row. Returns the
    /// new message's id.
    @discardableResult
    func sendMessage(chat: Int64, text: String, html: Bool, keyboard: [[TelegramButton]]) async throws -> Int64
    /// Replaces a message's text and its inline keyboard. An empty keyboard removes it.
    func editMessage(chat: Int64, messageID: Int64, text: String, keyboard: [[TelegramButton]]) async throws
    func answerCallback(id: String, text: String?, alert: Bool) async throws
    func sendChatAction(chat: Int64) async throws
    func getFile(id: String) async throws -> TelegramFilePath
    func download(path: String) async throws -> Data
}

extension TelegramClient {
    package func sendMessage(chat: Int64, text: String, html: Bool) async throws {
        try await sendMessage(chat: chat, text: text, html: html, keyboard: [])
    }

    /// `buttons` become one row.
    @discardableResult
    package func sendMessage(chat: Int64, text: String, html: Bool, buttons: [TelegramButton]) async throws -> Int64 {
        try await sendMessage(chat: chat, text: text, html: html, keyboard: buttons.isEmpty ? [] : [buttons])
    }

    /// Replaces a message's text and removes its inline keyboard.
    package func editMessage(chat: Int64, messageID: Int64, text: String) async throws {
        try await editMessage(chat: chat, messageID: messageID, text: text, keyboard: [])
    }
}

/// Sends one request and returns the status code and body. Swapped out in tests.
package protocol TelegramTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

package struct URLSessionTransport: TelegramTransport {
    package init() {}

    package func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TelegramError.network(error.localizedDescription)
        }
    }
}

/// The Telegram Bot API over HTTPS, with the bot token read from `token` for every call so a changed token takes
/// effect at once. The token is part of the URL path, so it never goes into a log line or an error message here.
package struct TelegramAPI: TelegramClient {
    package init(
        token: @escaping @Sendable () -> String?,
        transport: TelegramTransport = URLSessionTransport(),
        baseURL: String = TelegramAPI.defaultBase
    ) {
        self.token = token
        self.transport = transport
        self.baseURL = baseURL
    }

    package var token: @Sendable () -> String?
    package var transport: TelegramTransport = URLSessionTransport()
    package var baseURL: String = TelegramAPI.defaultBase

    package static let testMode = CommandLine.arguments.contains("--test-mode")

    package static var defaultBase: String {
        // A local fake Bot API for automated runs. Ignored outside test mode.
        if TelegramAPI.testMode, let override = ProcessInfo.processInfo.environment["IRONPET_TELEGRAM_API"] {
            return override
        }
        return "https://api.telegram.org"
    }

    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let result: T?
        let errorCode: Int?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case ok, result, description
            case errorCode = "error_code"
        }
    }

    private struct Empty: Decodable {}

    private func call<T: Decodable>(_ method: String, _ body: [String: Any], timeout: TimeInterval = 20, as: T.Type) async throws -> T {
        guard let token = token(), !token.isEmpty, let url = URL(string: "\(baseURL)/bot\(token)/\(method)") else {
            throw TelegramError.noToken
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await transport.send(request)
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw TelegramError.api(code: status, description: "Unexpected response")
        }
        guard envelope.ok, let result = envelope.result else {
            throw TelegramError.api(code: envelope.errorCode ?? status, description: envelope.description ?? "Unknown error")
        }
        return result
    }

    package func getMe() async throws -> TelegramUser {
        try await call("getMe", [:], as: TelegramUser.self)
    }

    package func getUpdates(offset: Int, timeout: Int) async throws -> [TelegramUpdate] {
        // The HTTP timeout has to outlast the long poll.
        try await call("getUpdates", ["offset": offset, "timeout": timeout, "allowed_updates": ["message", "callback_query"]],
                       timeout: TimeInterval(timeout + 15), as: [TelegramUpdate].self)
    }

    private static func markup(_ keyboard: [[TelegramButton]]) -> [String: Any] {
        ["inline_keyboard": keyboard.map { row in row.map { ["text": $0.text, "callback_data": $0.data] } }]
    }

    package func sendMessage(chat: Int64, text: String, html: Bool, keyboard: [[TelegramButton]]) async throws -> Int64 {
        var body: [String: Any] = ["chat_id": chat, "text": text, "disable_web_page_preview": true]
        if html { body["parse_mode"] = "HTML" }
        if !keyboard.isEmpty { body["reply_markup"] = Self.markup(keyboard) }
        return try await call("sendMessage", body, as: TelegramMessage.self).messageId
    }

    package func editMessage(chat: Int64, messageID: Int64, text: String, keyboard: [[TelegramButton]]) async throws {
        var body: [String: Any] = ["chat_id": chat, "message_id": messageID, "text": text, "disable_web_page_preview": true]
        if !keyboard.isEmpty { body["reply_markup"] = Self.markup(keyboard) }
        _ = try await call("editMessageText", body, as: TelegramMessage.self)
    }

    package func answerCallback(id: String, text: String?, alert: Bool) async throws {
        var body: [String: Any] = ["callback_query_id": id, "show_alert": alert]
        if let text { body["text"] = text }
        _ = try await call("answerCallbackQuery", body, as: Bool.self)
    }

    package func sendChatAction(chat: Int64) async throws {
        _ = try await call("sendChatAction", ["chat_id": chat, "action": "typing"], as: Bool.self)
    }

    package func getFile(id: String) async throws -> TelegramFilePath {
        try await call("getFile", ["file_id": id], as: TelegramFilePath.self)
    }

    /// The file's bytes. The path comes from `getFile`; downloads are capped by Telegram at 20 MB for bots.
    package func download(path: String) async throws -> Data {
        guard let token = token(), !token.isEmpty,
              let url = URL(string: "\(baseURL)/file/bot\(token)/\(path)") else { throw TelegramError.noToken }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "GET"
        let (data, status) = try await transport.send(request)
        guard status == 200 else { throw TelegramError.api(code: status, description: "Download failed") }
        return data
    }
}

/// Where the bot token lives. The Keychain in the app; memory in tests and in `--test-mode`, where a Keychain
/// approval dialog would block an automated run.
package protocol TelegramTokenStore: AnyObject, Sendable {
    func load() -> String?
    @discardableResult func save(_ token: String) -> Bool
}

extension TelegramTokenStore {
    package var isSet: Bool { load() != nil }
}

package final class MemoryTokenStore: TelegramTokenStore, @unchecked Sendable {
    package init() {}

    private let lock = NSLock()
    private var value: String?

    package func load() -> String? { lock.withLock { value } }

    package func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { value = trimmed.isEmpty ? nil : trimmed }
        return true
    }
}

/// The bot token, kept in the secret store (service `ironpet.telegram`) and never written to `~/.ironpet`.
package final class TelegramToken: TelegramTokenStore, @unchecked Sendable {
    package static let service = "ironpet.telegram"
    package static let account = "bot-token"

    private let secrets: SecretStore

    package init(secrets: SecretStore) { self.secrets = secrets }

    package func load() -> String? { secrets.text(service: Self.service, account: Self.account) }

    /// Stores `token`, replacing any earlier one. An empty token removes it.
    package func save(_ token: String) -> Bool { secrets.save(text: token, service: Self.service, account: Self.account) }
}
