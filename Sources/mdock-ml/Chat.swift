import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// OpenAI-compatible chat completions backed by Apple's on-device Foundation Model.
enum Chat {
    static let generalModel = "apple-foundation-model"
    static let taggingModel = "apple-foundation-model-content-tagging"

    /// Availability as (available, reason) without requiring macOS 26 at the call site.
    static func availability() -> (available: Bool, reason: String?) {
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return (true, nil)
            case .unavailable(.appleIntelligenceNotEnabled):
                return (false, "Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri.")
            case .unavailable(.deviceNotEligible):
                return (false, "This Mac is not eligible for Apple Intelligence.")
            case .unavailable(.modelNotReady):
                return (false, "The on-device model is not ready yet (still downloading or preparing). Try again later.")
            case .unavailable(let other):
                return (false, "The on-device model is unavailable: \(other)")
            }
        }
        return (false, "Foundation Models require macOS 26 or later.")
    }

    static func models(_ r: HTTPResponder) {
        let state = availability()
        let created = 1_749_427_200 // macOS 26 announcement
        let data: [[String: Any]] = [generalModel, taggingModel].map { id in
            var model: [String: Any] = ["id": id, "object": "model", "created": created, "owned_by": "apple",
                                        "available": state.available]
            if #available(macOS 26.0, *) { model["context_length"] = SystemLanguageModel.default.contextSize }
            if let reason = state.reason { model["unavailable_reason"] = reason }
            return model
        }
        r.json(200, ["object": "list", "data": data])
    }

    static func completions(_ req: HTTPRequest, _ r: HTTPResponder) throws {
        let body = try req.json()
        let state = availability()
        guard state.available else {
            throw HTTPError(503, state.reason ?? "model unavailable", type: "unavailable", code: "model_unavailable")
        }
        guard #available(macOS 26.0, *) else { throw HTTPError(503, "requires macOS 26") }
        try FMChat(body: body).run(r)
    }
}

#if canImport(FoundationModels)

/// Thrown from a client-side tool to stop generation and hand the call back to the client.
private struct ToolInterrupt: Error {}

@available(macOS 26.0, *)
private final class ToolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(name: String, arguments: String)] = []
    func record(_ name: String, _ arguments: String) { lock.withLock { calls.append((name, arguments)) } }
    var recorded: [(name: String, arguments: String)] { lock.withLock { calls } }
}

/// A tool defined by the client. Calling it ends generation; the client runs it (OpenAI semantics).
@available(macOS 26.0, *)
private struct ClientTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    let recorder: ToolRecorder

    func call(arguments: GeneratedContent) async throws -> String {
        recorder.record(name, arguments.jsonString)
        throw ToolInterrupt()
    }
}

@available(macOS 26.0, *)
private struct FMChat {
    let body: [String: Any]
    let modelID: String
    let model: SystemLanguageModel
    let options: GenerationOptions
    let stream: Bool
    let includeUsage: Bool
    let schema: GenerationSchema?
    let tools: [ClientTool]
    let recorder = ToolRecorder()
    let transcript: Transcript
    let prompt: Prompt
    let maxTokens: Int?
    let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
    let created = Int(Date().timeIntervalSince1970)

    init(body: [String: Any]) throws {
        self.body = body
        let requested = body["model"] as? String ?? Chat.generalModel
        if requested.contains("tagging") {
            modelID = Chat.taggingModel
            model = SystemLanguageModel(useCase: .contentTagging)
        } else {
            modelID = Chat.generalModel
            model = SystemLanguageModel.default
        }
        stream = body["stream"] as? Bool ?? false
        includeUsage = (body["stream_options"] as? [String: Any])?["include_usage"] as? Bool ?? false
        maxTokens = JSON.int(body["max_completion_tokens"]) ?? JSON.int(body["max_tokens"])
        var options = GenerationOptions(temperature: JSON.double(body["temperature"]), maximumResponseTokens: maxTokens)
        let seed = JSON.int(body["seed"]).map { UInt64(bitPattern: Int64($0)) }
        if let t = options.temperature, t <= 0 {
            options.sampling = .greedy
            options.temperature = nil
        } else if let topP = JSON.double(body["top_p"]), topP > 0, topP < 1 {
            options.sampling = .random(probabilityThreshold: topP, seed: seed)
        } else if let seed {
            options.sampling = .random(top: 50, seed: seed)
        }
        self.options = options

        // response_format
        var schema: GenerationSchema?
        var formatHint: String?
        if let format = body["response_format"] as? [String: Any] {
            switch format["type"] as? String {
            case "json_schema":
                guard let spec = format["json_schema"] as? [String: Any], let raw = spec["schema"] as? [String: Any] else {
                    throw HTTPError(400, "response_format.json_schema.schema is required")
                }
                schema = try SchemaConverter.generationSchema(raw, name: spec["name"] as? String ?? "Response")
            case "json_object":
                formatHint = "Respond with a single valid JSON object and nothing else."
            default: break
            }
        }
        self.schema = schema

        // tools
        let toolChoice = body["tool_choice"] as? String
        var tools: [ClientTool] = []
        if toolChoice != "none", let specs = body["tools"] as? [[String: Any]] {
            for spec in specs {
                guard let fn = spec["function"] as? [String: Any], let name = fn["name"] as? String else {
                    throw HTTPError(400, "each tool needs function.name")
                }
                let params = fn["parameters"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
                let parameters = try SchemaConverter.generationSchema(params, name: name + "Arguments")
                tools.append(ClientTool(name: name, description: fn["description"] as? String ?? name,
                                        parameters: parameters, recorder: recorder))
            }
        }
        self.tools = tools

        // messages → transcript + final prompt
        guard let messages = body["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw HTTPError(400, "messages must be a non-empty array")
        }
        var instructions: [String] = []
        var entries: [Transcript.Entry] = []
        var toolNames: [String: String] = [:]
        var finalPrompt: String?
        for (index, message) in messages.enumerated() {
            let role = message["role"] as? String ?? "user"
            let text = try FMChat.text(message["content"])
            let isLast = index == messages.count - 1
            switch role {
            case "system", "developer":
                instructions.append(text)
            case "user":
                if isLast { finalPrompt = text } else {
                    entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: text))])))
                }
            case "assistant":
                if !text.isEmpty {
                    entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: text))])))
                }
                if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    var converted: [Transcript.ToolCall] = []
                    for call in calls {
                        let fn = call["function"] as? [String: Any] ?? [:]
                        let callID = call["id"] as? String ?? UUID().uuidString
                        let name = fn["name"] as? String ?? "tool"
                        toolNames[callID] = name
                        let args = (try? GeneratedContent(json: fn["arguments"] as? String ?? "{}"))
                            ?? GeneratedContent(properties: [:])
                        converted.append(Transcript.ToolCall(id: callID, toolName: name, arguments: args))
                    }
                    entries.append(.toolCalls(Transcript.ToolCalls(converted)))
                }
            case "tool":
                let callID = message["tool_call_id"] as? String ?? ""
                entries.append(.toolOutput(Transcript.ToolOutput(
                    id: callID, toolName: toolNames[callID] ?? message["name"] as? String ?? "tool",
                    segments: [.text(.init(content: text))])))
            default:
                throw HTTPError(400, "unsupported message role \(role)")
            }
        }
        if let formatHint { instructions.append(formatHint) }
        var all: [Transcript.Entry] = []
        if !instructions.isEmpty || !tools.isEmpty {
            all.append(.instructions(Transcript.Instructions(
                segments: instructions.isEmpty ? [] : [.text(.init(content: instructions.joined(separator: "\n\n")))],
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) })))
        }
        all += entries
        transcript = Transcript(entries: all)
        prompt = Prompt(finalPrompt ?? "Continue. Use the tool results above to answer the user's last request.")
    }

    /// Flattens OpenAI message content (string or text parts) to a string.
    static func text(_ content: Any?) throws -> String {
        if content == nil || content is NSNull { return "" }
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            return try parts.map { part in
                switch part["type"] as? String {
                case "text", "input_text": return part["text"] as? String ?? ""
                default: throw HTTPError(400, "only text content parts are supported (got \(part["type"] ?? "?"))")
                }
            }.joined(separator: "\n")
        }
        throw HTTPError(400, "message content must be a string or an array of parts")
    }

    func session() -> LanguageModelSession {
        LanguageModelSession(model: model, tools: tools, transcript: transcript)
    }

    func run(_ r: HTTPResponder) throws {
        if stream { try runStream(r) } else { try runOnce(r) }
    }

    // MARK: non-streaming

    private func runOnce(_ r: HTTPResponder) throws {
        let session = session()
        let start = DispatchTime.now()
        let outcome: (text: String?, calls: [[String: Any]]) = try blocking {
            do {
                if let schema {
                    let response = try await session.respond(to: prompt, schema: schema, options: options)
                    return (response.content.jsonString, [])
                }
                return (try await session.respond(to: prompt, options: options).content, [])
            } catch {
                if let calls = toolCalls(after: error, session: session) { return (nil, calls) }
                throw FMChat.map(error)
            }
        }
        let elapsed = milliseconds(since: start)
        let usage = usage(session: session, completion: outcome.text ?? JSON.string(outcome.calls))
        var message: [String: Any] = ["role": "assistant", "content": outcome.text.map { $0 as Any } ?? NSNull()]
        var finish = "stop"
        if !outcome.calls.isEmpty {
            message["tool_calls"] = outcome.calls
            finish = "tool_calls"
        } else if let maxTokens, usage.completion >= maxTokens {
            finish = "length"
        }
        Log.info("chat: \(usage.prompt)+\(usage.completion) tokens in \(Int(elapsed))ms")
        r.json(200, [
            "id": id, "object": "chat.completion", "created": created, "model": modelID,
            "choices": [["index": 0, "message": message, "finish_reason": finish, "logprobs": NSNull()]],
            "usage": usage.json,
            "timing": ["total_ms": rounded(elapsed),
                       "tokens_per_second": elapsed > 0 ? rounded(Double(usage.completion) / elapsed * 1000) : 0],
        ])
    }

    // MARK: streaming

    private func chunk(_ delta: [String: Any], finish: String? = nil) -> [String: Any] {
        ["id": id, "object": "chat.completion.chunk", "created": created, "model": modelID,
         "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull(), "logprobs": NSNull()]]]
    }

    private func runStream(_ r: HTTPResponder) throws {
        let session = session()
        let start = DispatchTime.now()
        var firstToken: Double?
        var sentHeader = false

        func header() throws {
            guard !sentHeader else { return }
            sentHeader = true
            try r.begin(200, contentType: "text/event-stream")
            try r.event(chunk(["role": "assistant", "content": ""]))
        }

        let result: (text: String, calls: [[String: Any]])
        do {
            result = try streamBody(session: session, start: start, firstToken: &firstToken, header: header, r: r)
        } catch let error as HTTPError where sentHeader {
            // Mid-stream failure: report it as an SSE error event, then end the stream.
            try r.event(error.body)
            try r.chunk(Data("data: [DONE]\n\n".utf8))
            return
        }
        // Errors before the first byte become a normal JSON error (handled by the server).
        try finishStream(r, session: session, result: result, start: start, firstToken: firstToken, header: header)
    }

    private func streamBody(session: LanguageModelSession, start: DispatchTime, firstToken: inout Double?,
                            header: @escaping () throws -> Void, r: HTTPResponder) throws -> (text: String, calls: [[String: Any]]) {
        var first: Double?
        defer { firstToken = first }
        return try blocking {
            var sent = ""
            do {
                if let schema {
                    // Guided generation: partial JSON snapshots are not prefix-stable, so send the final object.
                    let response = try await session.respond(to: prompt, schema: schema, options: options)
                    let json = response.content.jsonString
                    first = milliseconds(since: start)
                    try header()
                    try r.event(chunk(["content": json]))
                    return (json, [])
                }
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    let text = snapshot.content
                    let delta: String
                    if text.hasPrefix(sent) { delta = String(text.dropFirst(sent.count)) }
                    else { delta = String(text.dropFirst(sent.commonPrefix(with: text).count)) }
                    sent = text
                    guard !delta.isEmpty else { continue }
                    if first == nil { first = milliseconds(since: start) }
                    try header()
                    try r.event(chunk(["content": delta]))
                }
                return (sent, [])
            } catch is WriteFailed {
                throw WriteFailed()
            } catch {
                if let calls = toolCalls(after: error, session: session) { return (sent, calls) }
                throw FMChat.map(error)
            }
        }
    }

    private func finishStream(_ r: HTTPResponder, session: LanguageModelSession, result: (text: String, calls: [[String: Any]]),
                              start: DispatchTime, firstToken: Double?, header: () throws -> Void) throws {
        try header()
        let elapsed = milliseconds(since: start)
        let usage = usage(session: session, completion: result.text + (result.calls.isEmpty ? "" : JSON.string(result.calls)))
        var finish = "stop"
        if !result.calls.isEmpty {
            let indexed = result.calls.enumerated().map { i, call -> [String: Any] in
                var call = call
                call["index"] = i
                return call
            }
            try r.event(chunk(["tool_calls": indexed]))
            finish = "tool_calls"
        } else if let maxTokens, usage.completion >= maxTokens {
            finish = "length"
        }
        try r.event(chunk([:], finish: finish))
        if includeUsage {
            try r.event(["id": id, "object": "chat.completion.chunk", "created": created, "model": modelID,
                         "choices": [Any](), "usage": usage.json])
        }
        try r.chunk(Data("data: [DONE]\n\n".utf8))
        let genSeconds = (elapsed - (firstToken ?? 0)) / 1000
        Log.info("chat stream: ttft \(Int(firstToken ?? 0))ms, \(usage.completion) tokens in \(Int(elapsed))ms"
                 + (genSeconds > 0 ? String(format: " (%.1f tok/s after first)", Double(max(usage.completion - 1, 0)) / genSeconds) : ""))
    }

    // MARK: helpers

    /// When a client tool interrupted generation, returns the calls in OpenAI form.
    private func toolCalls(after error: Error, session: LanguageModelSession) -> [[String: Any]]? {
        guard let toolError = error as? LanguageModelSession.ToolCallError, toolError.underlyingError is ToolInterrupt else {
            return nil
        }
        var calls: [[String: Any]] = []
        for entry in session.transcript.reversed() {
            if case .toolCalls(let toolCalls) = entry {
                calls = toolCalls.map { call in
                    ["id": "call_" + call.id.replacingOccurrences(of: "-", with: "").prefix(24).lowercased(),
                     "type": "function",
                     "function": ["name": call.toolName, "arguments": call.arguments.jsonString]]
                }
                break
            }
        }
        if calls.isEmpty {
            calls = recorder.recorded.map { call in
                ["id": "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased(),
                 "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
            }
        }
        return calls
    }

    private struct Usage {
        var prompt: Int
        var completion: Int
        var exact: Bool
        var json: [String: Any] {
            ["prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion,
             "estimated": !exact]
        }
    }

    /// Token counts from the model's tokenizer (macOS 26.4+), else a 4-chars-per-token estimate.
    private func usage(session: LanguageModelSession, completion: String) -> Usage {
        let promptEntries = Array(session.transcript.filter {
            if case .response = $0 { return false }
            return true
        })
        let estimate = Usage(prompt: promptEntries.map { "\($0)".count }.reduce(0, +) / 4,
                             completion: max(1, completion.count / 4), exact: false)
        if #available(macOS 26.4, *) {
            let model = self.model
            let counted: (Int, Int)? = try? blocking {
                let p = try await model.tokenCount(for: promptEntries)
                let c = try await model.tokenCount(for: Prompt(completion))
                return (p, c)
            }
            if let counted { return Usage(prompt: counted.0, completion: counted.1, exact: true) }
        }
        return estimate
    }

    static func map(_ error: Error) -> Error {
        if error is HTTPError || error is WriteFailed { return error }
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return HTTPError(500, error.localizedDescription)
        }
        let message = [generation.errorDescription, generation.failureReason]
            .compactMap { $0 }.joined(separator: ": ")
        switch generation {
        case .exceededContextWindowSize:
            return HTTPError(400, message + " (the on-device model has a 4096-token context)", code: "context_length_exceeded")
        case .assetsUnavailable: return HTTPError(503, message, type: "unavailable", code: "model_unavailable")
        case .guardrailViolation: return HTTPError(400, message, code: "content_filter")
        case .refusal: return HTTPError(400, message, code: "refusal")
        case .unsupportedGuide: return HTTPError(400, message, code: "unsupported_schema")
        case .unsupportedLanguageOrLocale: return HTTPError(400, message, code: "unsupported_language")
        case .decodingFailure: return HTTPError(500, message, code: "decoding_failure")
        case .rateLimited: return HTTPError(429, message, code: "rate_limited")
        case .concurrentRequests: return HTTPError(429, message, code: "concurrent_requests")
        @unknown default: return HTTPError(500, message)
        }
    }
}

/// Converts JSON Schema (the subset OpenAI structured outputs use) into a `GenerationSchema`.
@available(macOS 26.0, *)
struct SchemaConverter {
    private var definitions: [String: [String: Any]] = [:]
    private var dependencies: [String: DynamicGenerationSchema] = [:]
    private var pending: Set<String> = []
    private var used: Set<String> = []

    static func generationSchema(_ schema: [String: Any], name: String) throws -> GenerationSchema {
        var converter = SchemaConverter()
        converter.definitions = (schema["$defs"] as? [String: [String: Any]]) ?? (schema["definitions"] as? [String: [String: Any]]) ?? [:]
        let root = try converter.convert(schema, name: name)
        do {
            return try GenerationSchema(root: root, dependencies: Array(converter.dependencies.values))
        } catch {
            throw HTTPError(400, "unsupported JSON schema: \(error.localizedDescription)", code: "unsupported_schema")
        }
    }

    private mutating func uniqueName(_ base: String) -> String {
        let cleaned = base.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        var name = cleaned.isEmpty ? "Type" : cleaned
        var n = 2
        while used.contains(name) || definitions[name] != nil {
            name = (cleaned.isEmpty ? "Type" : cleaned) + "\(n)"
            n += 1
        }
        used.insert(name)
        return name
    }

    private mutating func convert(_ s: [String: Any], name: String) throws -> DynamicGenerationSchema {
        let description = s["description"] as? String
        if let ref = s["$ref"] as? String {
            let key = String(ref.split(separator: "/").last ?? "")
            guard let def = definitions[key] else { throw HTTPError(400, "unresolved $ref \(ref)", code: "unsupported_schema") }
            if dependencies[key] == nil && !pending.contains(key) {
                pending.insert(key)
                dependencies[key] = try convertNamed(def, name: key)
            }
            return DynamicGenerationSchema(referenceTo: key)
        }
        if let choices = (s["anyOf"] ?? s["oneOf"]) as? [[String: Any]] {
            let nonNull = choices.filter { ($0["type"] as? String) != "null" }
            if nonNull.count == 1 { return try convert(nonNull[0], name: name) }
            let converted = try nonNull.enumerated().map { try convert($1, name: "\(name)Option\($0)") }
            return DynamicGenerationSchema(name: uniqueName(name), description: description, anyOf: converted)
        }
        if let values = s["enum"] as? [Any] {
            return DynamicGenerationSchema(name: uniqueName(name), description: description,
                                           anyOf: values.map { $0 as? String ?? JSON.string($0) })
        }
        if let constant = s["const"] {
            return DynamicGenerationSchema(name: uniqueName(name), description: description,
                                           anyOf: [constant as? String ?? JSON.string(constant)])
        }
        var type = s["type"] as? String
        if let types = s["type"] as? [String] { type = types.first { $0 != "null" } }
        if type == nil { type = s["properties"] != nil ? "object" : (s["items"] != nil ? "array" : "string") }
        switch type {
        case "object":
            return try convertNamed(s, name: name)
        case "array":
            let items = s["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(arrayOf: try convert(items, name: name + "Item"),
                                           minimumElements: JSON.int(s["minItems"]), maximumElements: JSON.int(s["maxItems"]))
        case "integer":
            var guides: [GenerationGuide<Int>] = []
            if let min = JSON.int(s["minimum"]) { guides.append(.minimum(min)) }
            if let max = JSON.int(s["maximum"]) { guides.append(.maximum(max)) }
            return DynamicGenerationSchema(type: Int.self, guides: guides)
        case "number":
            var guides: [GenerationGuide<Double>] = []
            if let min = JSON.double(s["minimum"]) { guides.append(.minimum(min)) }
            if let max = JSON.double(s["maximum"]) { guides.append(.maximum(max)) }
            return DynamicGenerationSchema(type: Double.self, guides: guides)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "string":
            var guides: [GenerationGuide<String>] = []
            if let pattern = s["pattern"] as? String, let regex = try? Regex(pattern) { guides.append(.pattern(regex)) }
            return DynamicGenerationSchema(type: String.self, guides: guides)
        default:
            throw HTTPError(400, "unsupported JSON schema type \(type ?? "?")", code: "unsupported_schema")
        }
    }

    private mutating func convertNamed(_ s: [String: Any], name: String) throws -> DynamicGenerationSchema {
        if (s["type"] as? String) != "object" && s["properties"] == nil { return try convert(s, name: name) }
        let required = Set(s["required"] as? [String] ?? [])
        let properties = s["properties"] as? [String: Any] ?? [:]
        // Keep the schema's key order where the JSON parser preserved it; otherwise required first.
        let keys = properties.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }
        var converted: [DynamicGenerationSchema.Property] = []
        for key in keys {
            let prop = properties[key] as? [String: Any] ?? [:]
            converted.append(.init(name: key, description: prop["description"] as? String,
                                   schema: try convert(prop, name: key.capitalized), isOptional: !required.contains(key)))
        }
        let title = s["title"] as? String ?? name
        return DynamicGenerationSchema(name: definitions[name] != nil ? name : uniqueName(title),
                                       description: s["description"] as? String, properties: converted)
    }
}

#endif
