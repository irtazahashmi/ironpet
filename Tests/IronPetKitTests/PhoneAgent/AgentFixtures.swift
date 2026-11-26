import Foundation

/// Server-sent event streams in the shape the two providers document for streaming. They are written by hand from the API references, not
/// recorded from a live account, so a change in a provider's stream is caught by the manual check on a device, not by these.
enum AgentFixtures {
    /// Anthropic Messages: a short answer in three text deltas.
    static let anthropicText = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5-5","stop_reason":null,"usage":{"input_tokens":10,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: ping
        data: {"type":"ping"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"That needs "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"the Mac. "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Ask the agent there."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}}

        event: message_stop
        data: {"type":"message_stop"}

        """

    /// Anthropic Messages: a sentence of text, then a tool call whose arguments arrive in three pieces.
    static func anthropicToolCall(name: String = "inbox_add", id: String = "toolu_01", arguments: [String]) -> String {
        let pieces = arguments.map { piece -> String in
            let escaped = piece.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return """
            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\(escaped)"}}


            """
        }.joined()
        return """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5-5","stop_reason":null}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Adding that."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"\(id)","name":"\(name)","input":{}}}

        \(pieces)event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":40}}

        event: message_stop
        data: {"type":"message_stop"}

        """
    }

    /// OpenAI Responses: a short answer in two text deltas.
    static let openAIText = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Done: "}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"call Tom is in your inbox."}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed"}}

        """

    /// OpenAI Responses: a function call whose arguments arrive in pieces, then finish as one item.
    static func openAIToolCall(name: String = "inbox_add", callID: String = "call_01", arguments: String) -> String {
        let escaped = arguments.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let half = escaped.index(escaped.startIndex, offsetBy: escaped.count / 2)
        return """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_2","status":"in_progress"}}

        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"\(callID)","name":"\(name)","arguments":""}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"\(escaped[..<half])"}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"\(escaped[half...])"}

        event: response.function_call_arguments.done
        data: {"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":0,"arguments":"\(escaped)"}

        event: response.output_item.done
        data: {"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"\(callID)","name":"\(name)","arguments":"\(escaped)"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_2","status":"completed"}}

        """
    }
}
