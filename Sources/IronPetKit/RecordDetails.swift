import Foundation

/// A record the Mac answers for a public id in chat, as the phone shows it: its kind, its ids, and its fields as name and value text.
/// The Mac sends the fields of a kind it can read; any other kind has none, and the phone says to open it on the Mac.
public struct RecordDetails: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public let kind: String
    public let ref: String
    public let key: String
    /// Top-level values in name order, then one level of nested objects as `parent.child`. Lists and nulls are left out.
    public let fields: [Field]

    /// The record's kind for a person, as the sheet's title.
    public var title: String { Self.kindNames[kind] ?? kind }

    /// The answer to `GET /v1/records/:id`. Throws when it is not an object with a kind, a ref and a key.
    public init(json data: Data) throws {
        let root = try JSONDecoder().decode([String: Value].self, from: data)
        guard case .text(let kind)? = root["kind"], case .text(let ref)? = root["ref"], case .text(let key)? = root["key"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "a record needs a kind, a ref and a key"))
        }
        self.kind = kind
        self.ref = ref
        self.key = key
        var fields: [Field] = []
        for name in root.keys.filter({ !Self.identity.contains($0) }).sorted() {
            switch root[name] {
            case .object(let nested)?:
                for child in nested.keys.sorted() {
                    if let text = nested[child]?.text { fields.append(Field(name: "\(name).\(child)", value: text)) }
                }
            case let value?:
                if let text = value.text { fields.append(Field(name: name, value: text)) }
            case nil:
                break
            }
        }
        self.fields = fields
    }

    public init(kind: String, ref: String, key: String, fields: [Field]) {
        self.kind = kind
        self.ref = ref
        self.key = key
        self.fields = fields
    }

    private static let identity: Set<String> = ["kind", "ref", "key"]

    private static let kindNames: [String: String] = [
        "screen": "Capture", "notif": "Notification", "meeting": "Meeting", "chat": "Chat", "msg": "Message", "task": "Task",
        "auto": "Automation", "run": "Run", "job": "Job", "page": "Memory page", "claim": "Memory claim", "filter": "Quick filter",
    ]

    /// One JSON value the sheet can show. Numbers that are whole print without a decimal point; `true` and `false` print as yes and no.
    private indirect enum Value: Decodable {
        case text(String)
        case flag(Bool)
        case number(Double)
        case object([String: Value])
        case other

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let flag = try? single.decode(Bool.self) {
                self = .flag(flag)
            } else if let number = try? single.decode(Double.self) {
                self = .number(number)
            } else if let text = try? single.decode(String.self) {
                self = .text(text)
            } else if let object = try? single.decode([String: Value].self) {
                self = .object(object)
            } else {
                self = .other
            }
        }

        var text: String? {
            switch self {
            case .text(let text): return text
            case .flag(let flag): return flag ? "yes" : "no"
            case .number(let number):
                return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
            case .object, .other: return nil
            }
        }
    }
}
