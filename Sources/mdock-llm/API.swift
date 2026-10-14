import Foundation

/// The HTTP front end: OpenAI-compatible routes proxied byte-for-byte to llama-server, and
/// Ollama-compatible routes translated to them.
final class API {
    let pool: Pool
    let store: ModelStore

    init(pool: Pool, store: ModelStore) {
        self.pool = pool
        self.store = store
    }

    /// Serves one request, then closes the connection.
    func handle(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let reader = Reader(fd)
        let request: HTTPRequest
        do {
            guard let parsed = try HTTPRequest.read(reader) else { return }
            request = parsed
        } catch let error as LLMError {
            HTTPResponse.error(fd, status: error.status, error.description)
            return
        } catch {
            return
        }
        do {
            try route(fd, request)
        } catch let error as LLMError {
            HTTPResponse.error(fd, status: error.status, error.description)
        } catch {
            HTTPResponse.error(fd, status: 500, "\(error)")
        }
    }

    private func route(_ fd: Int32, _ request: HTTPRequest) throws {
        var path = request.path
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        switch (request.method, path) {
        case ("GET", "/"), ("HEAD", "/"):
            HTTPResponse.send(fd, contentType: "text/plain", body: Data("mdock-llm is running".utf8))
        case ("GET", "/health"):
            HTTPResponse.json(fd, ["status": "ok"])
        case ("GET", "/v1/models"), ("GET", "/models"):
            HTTPResponse.json(fd, ["object": "list", "data": store.list().map(openAIModel)])
        case ("GET", _) where path.hasPrefix("/v1/models/"):
            let id = String(path.dropFirst("/v1/models/".count)).removingPercentEncoding ?? ""
            guard let model = store.find(id) else { throw LLMError(description: "model '\(id)' not found", status: 404) }
            HTTPResponse.json(fd, openAIModel(model))
        case ("POST", "/v1/embeddings"), ("POST", "/embeddings"):
            try proxy(fd, request, kind: .embed)
        case ("POST", _) where path.hasPrefix("/v1/"):
            try proxy(fd, request, kind: .generate)
        case ("POST", "/completion"), ("POST", "/completions"), ("POST", "/chat/completions"),
             ("POST", "/tokenize"), ("POST", "/detokenize"), ("POST", "/apply-template"), ("POST", "/infill"):
            try proxy(fd, request, kind: .generate)

        // Ollama
        case ("GET", "/api/version"):
            HTTPResponse.json(fd, ["version": "0.6.0"])
        case ("GET", "/api/tags"):
            HTTPResponse.json(fd, ["models": store.list().map(ollamaModel)])
        case ("GET", "/api/ps"):
            HTTPResponse.json(fd, ["models": pool.loaded.filter { $0.kind == .generate }.map { instance -> [String: Any] in
                var entry = ollamaModel(instance.model)
                entry["size_vram"] = instance.memory
                entry["expires_at"] = iso(instance.lastUsed.addingTimeInterval(pool.settings.idleSeconds))
                return entry
            }])
        case ("POST", "/api/show"):
            try ollamaShow(fd, request)
        case ("POST", "/api/pull"):
            try ollamaPull(fd, request)
        case ("POST", "/api/chat"):
            try ollamaChat(fd, request, generate: false)
        case ("POST", "/api/generate"):
            try ollamaChat(fd, request, generate: true)
        case ("POST", "/api/embed"), ("POST", "/api/embeddings"):
            try ollamaEmbed(fd, request, legacy: path == "/api/embeddings")
        default:
            throw LLMError(description: "\(request.method) \(path) is not supported by mdock-llm", status: 404)
        }
    }

    // MARK: OpenAI proxy

    /// The model a request names, or the only sensible default when it names none.
    private func modelID(_ body: [String: Any]?) throws -> String {
        if let id = body?["model"] as? String, !id.isEmpty { return id }
        let loaded = pool.loaded.filter { $0.kind == .generate }
        if loaded.count == 1 { return loaded[0].model.id }
        let models = store.list()
        if models.count == 1 { return models[0].id }
        throw LLMError(description: "request needs a \"model\" (see GET /v1/models)", status: 400)
    }

    /// Forwards the request to the model's llama-server and copies the response back unchanged as
    /// it arrives, so SSE streams are not buffered.
    private func proxy(_ fd: Int32, _ request: HTTPRequest, kind: InstanceKind) throws {
        guard let body = request.json else { throw LLMError(description: "body must be a JSON object", status: 400) }
        let instance = try pool.acquire(try modelID(body), kind: kind)
        defer { pool.release(instance) }
        guard let upstream = Sockets.tcpConnect(host: "127.0.0.1", port: instance.port) else {
            pool.checkAlive(instance)
            throw LLMError(description: "llama-server for \(instance.model.id) is not reachable", status: 502)
        }
        defer { close(upstream) }
        var head = "\(request.method) \(request.target) HTTP/1.1\r\nHost: 127.0.0.1:\(instance.port)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(request.body.count)\r\nConnection: close\r\n"
        if let accept = request.headers["Accept"] { head += "Accept: \(accept)\r\n" }
        head += "\r\n"
        guard Sockets.writeAll(upstream, head), Sockets.writeAll(upstream, request.body) else {
            throw LLMError(description: "llama-server for \(instance.model.id) closed the connection", status: 502)
        }
        relay(from: upstream, to: fd)
    }

    /// Copies upstream to the client until EOF. If the client goes away the upstream connection is
    /// closed, which makes llama-server cancel the generation.
    private func relay(from upstream: Int32, to client: Int32) {
        let size = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var fds = [pollfd(fd: upstream, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: client, events: Int16(POLLIN), revents: 0)]
        while true {
            let ready = poll(&fds, 2, -1)
            if ready < 0 { if errno == EINTR { continue }; return }
            if fds[1].revents & Int16(POLLHUP | POLLERR) != 0 { return }
            if fds[1].revents & Int16(POLLIN) != 0 {
                // Extra bytes or a half-close from the client: stop watching it. A client that has
                // really gone shows up as POLLHUP or as a failed write below.
                fds[1].events = 0
                fds[1].fd = -1
            }
            if fds[0].revents != 0 {
                let n = read(upstream, buffer, size)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                if !Sockets.writeAll(client, UnsafeRawPointer(buffer), n) { return }
            }
        }
    }

    /// Sends a JSON request to llama-server and returns the response status, headers and reader.
    private func call(_ instance: Instance, path: String, body: [String: Any]) throws -> (Int, HTTPHeaders, Reader, Int32) {
        guard let upstream = Sockets.tcpConnect(host: "127.0.0.1", port: instance.port) else {
            pool.checkAlive(instance)
            throw LLMError(description: "llama-server for \(instance.model.id) is not reachable", status: 502)
        }
        let data = jsonData(body)
        Sockets.writeAll(upstream, "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(instance.port)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n")
        Sockets.writeAll(upstream, data)
        let reader = Reader(upstream)
        guard let statusLine = reader.readLine(), let headers = HTTPHeaders.read(reader) else {
            close(upstream)
            throw LLMError(description: "no response from llama-server", status: 502)
        }
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 502
        return (status, headers, reader, upstream)
    }

    private func callJSON(_ instance: Instance, path: String, body: [String: Any]) throws -> [String: Any] {
        let (status, headers, reader, upstream) = try call(instance, path: path, body: body)
        defer { close(upstream) }
        let data = HTTPBody.read(reader, headers: headers, untilEOF: true, limit: 512 << 20) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(500), as: UTF8.self)
            throw LLMError(description: message, status: status)
        }
        return object
    }

    // MARK: Ollama

    private func ollamaChat(_ fd: Int32, _ request: HTTPRequest, generate: Bool) throws {
        guard let body = request.json else { throw LLMError(description: "body must be a JSON object", status: 400) }
        let id = try modelID(body)
        let stream = body["stream"] as? Bool ?? true
        let started = Date()

        var openAI: [String: Any] = ["model": id, "stream": stream]
        var path = "/v1/chat/completions"
        if generate {
            let prompt = body["prompt"] as? String ?? ""
            if prompt.isEmpty && (body["images"] == nil) {
                // Ollama clients send an empty prompt to preload a model.
                let instance = try pool.acquire(id, kind: .generate)
                pool.release(instance)
                HTTPResponse.json(fd, ["model": id, "created_at": iso(Date()), "response": "", "done": true, "done_reason": "load"])
                return
            }
            if body["raw"] as? Bool == true {
                path = "/v1/completions"
                openAI["prompt"] = prompt
            } else {
                var messages: [[String: Any]] = []
                if let system = body["system"] as? String, !system.isEmpty { messages.append(["role": "system", "content": system]) }
                messages.append(["role": "user", "content": prompt])
                openAI["messages"] = messages
            }
        } else {
            openAI["messages"] = (body["messages"] as? [[String: Any]] ?? []).map(openAIMessage)
            if let tools = body["tools"] { openAI["tools"] = tools }
        }
        if stream { openAI["stream_options"] = ["include_usage": true] }
        applyOptions(body, to: &openAI)

        let instance = try pool.acquire(id, kind: .generate)
        defer { pool.release(instance) }
        let loaded = Date()
        let (status, headers, reader, upstream) = try call(instance, path: path, body: openAI)
        defer { close(upstream) }
        let field = generate ? "response" : "message"

        func frame(_ text: String, toolCalls: [[String: Any]]? = nil) -> [String: Any] {
            var object: [String: Any] = ["model": id, "created_at": iso(Date()), "done": false]
            if generate {
                object[field] = text
            } else {
                var message: [String: Any] = ["role": "assistant", "content": text]
                if let toolCalls, !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
                object[field] = message
            }
            return object
        }
        func finish(_ object: inout [String: Any], reason: String?, timings: [String: Any]?, usage: [String: Any]?) {
            object["done"] = true
            object["done_reason"] = reason == "length" ? "length" : "stop"
            object["total_duration"] = Int(Date().timeIntervalSince(started) * 1e9)
            object["load_duration"] = Int(loaded.timeIntervalSince(started) * 1e9)
            let promptN = (usage?["prompt_tokens"] as? Int) ?? (timings?["prompt_n"] as? Int) ?? 0
            let predictedN = (usage?["completion_tokens"] as? Int) ?? (timings?["predicted_n"] as? Int) ?? 0
            object["prompt_eval_count"] = promptN
            object["eval_count"] = predictedN
            object["prompt_eval_duration"] = Int(((timings?["prompt_ms"] as? Double) ?? 0) * 1e6)
            object["eval_duration"] = Int(((timings?["predicted_ms"] as? Double) ?? 0) * 1e6)
        }

        guard status == 200 else {
            let data = HTTPBody.read(reader, headers: headers, untilEOF: true, limit: 1 << 20) ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(500), as: UTF8.self)
            HTTPResponse.json(fd, status: status, ["error": message])
            return
        }

        if !stream {
            let data = HTTPBody.read(reader, headers: headers, untilEOF: true, limit: 512 << 20) ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let choice = (object["choices"] as? [[String: Any]])?.first ?? [:]
            let message = choice["message"] as? [String: Any] ?? [:]
            let text = (message["content"] as? String) ?? (choice["text"] as? String) ?? ""
            var out = frame(text, toolCalls: (message["tool_calls"] as? [[String: Any]]).map(ollamaToolCalls))
            if !generate, let reasoning = message["reasoning_content"] as? String, var m = out["message"] as? [String: Any] {
                m["thinking"] = reasoning
                out["message"] = m
            }
            finish(&out, reason: choice["finish_reason"] as? String, timings: object["timings"] as? [String: Any],
                   usage: object["usage"] as? [String: Any])
            HTTPResponse.json(fd, out)
            return
        }

        guard HTTPResponse.beginChunked(fd, contentType: "application/x-ndjson") else { return }
        var pending = ""
        var reason: String?
        var timings: [String: Any]?
        var usage: [String: Any]?
        var tools: [Int: (name: String, arguments: String)] = [:]
        var clientGone = false
        _ = HTTPBody.stream(reader, headers: headers, untilEOF: true) { piece in
            pending += String(decoding: piece, as: UTF8.self)
            while let newline = pending.firstIndex(of: "\n") {
                let line = pending[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
                pending = String(pending[pending.index(after: newline)...])
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { continue }
                guard let chunk = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                if let t = chunk["timings"] as? [String: Any] { timings = t }
                if let u = chunk["usage"] as? [String: Any] { usage = u }
                guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
                if let r = choice["finish_reason"] as? String { reason = r }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = call["index"] as? Int ?? 0
                    let function = call["function"] as? [String: Any] ?? [:]
                    var entry = tools[index] ?? ("", "")
                    entry.name += function["name"] as? String ?? ""
                    entry.arguments += function["arguments"] as? String ?? ""
                    tools[index] = entry
                }
                let text = (delta["content"] as? String) ?? (choice["text"] as? String) ?? ""
                let thinking = delta["reasoning_content"] as? String ?? ""
                if text.isEmpty && thinking.isEmpty { continue }
                var out = frame(text)
                if !thinking.isEmpty, var m = out["message"] as? [String: Any] {
                    m["thinking"] = thinking
                    out["message"] = m
                }
                var encoded = jsonData(out)
                encoded.append(10)
                if !HTTPResponse.chunk(fd, encoded) { clientGone = true; return false }
            }
            return true
        }
        if clientGone { return }
        let toolCalls = tools.keys.sorted().map { index -> [String: Any] in
            ["function": ["name": tools[index]!.name, "arguments": decodeArguments(tools[index]!.arguments)]]
        }
        var last = frame("", toolCalls: toolCalls)
        finish(&last, reason: reason, timings: timings, usage: usage)
        var line = jsonData(last)
        line.append(10)
        HTTPResponse.chunk(fd, line)
        HTTPResponse.endChunked(fd)
    }

    private func ollamaEmbed(_ fd: Int32, _ request: HTTPRequest, legacy: Bool) throws {
        guard let body = request.json else { throw LLMError(description: "body must be a JSON object", status: 400) }
        let id = try modelID(body)
        let input: Any = legacy ? (body["prompt"] ?? "") : (body["input"] ?? "")
        let started = Date()
        let instance = try pool.acquire(id, kind: .embed)
        defer { pool.release(instance) }
        let result = try callJSON(instance, path: "/v1/embeddings", body: ["model": id, "input": input])
        let vectors = (result["data"] as? [[String: Any]] ?? [])
            .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
            .map { $0["embedding"] ?? [] }
        if legacy {
            HTTPResponse.json(fd, ["embedding": vectors.first ?? []])
        } else {
            let usage = result["usage"] as? [String: Any]
            HTTPResponse.json(fd, ["model": id, "embeddings": vectors,
                                   "total_duration": Int(Date().timeIntervalSince(started) * 1e9),
                                   "prompt_eval_count": usage?["prompt_tokens"] as? Int ?? 0])
        }
    }

    private func ollamaShow(_ fd: Int32, _ request: HTTPRequest) throws {
        let body = request.json ?? [:]
        let id = (body["model"] as? String) ?? (body["name"] as? String) ?? ""
        guard let model = store.find(id) else { throw LLMError(description: "model '\(id)' not found", status: 404) }
        let info = GGUFInfo.read(model.url)
        let arch = info?.architecture ?? ""
        HTTPResponse.json(fd, [
            "modelfile": "", "parameters": "", "template": "",
            "details": ["format": "gguf", "family": arch, "families": [arch], "parameter_size": "", "quantization_level": ""],
            "model_info": ["general.architecture": arch, "\(arch).context_length": info?.contextLength ?? 0,
                           "\(arch).embedding_length": info?.embeddingLength ?? 0],
            "capabilities": info?.hasPoolingType == true ? ["embedding"] : ["completion", "tools"],
            "modified_at": iso(model.modified),
        ])
    }

    /// Downloads a Hugging Face model (`owner/repo:file.gguf` or `owner/repo:QUANT`).
    private func ollamaPull(_ fd: Int32, _ request: HTTPRequest) throws {
        let body = request.json ?? [:]
        let id = (body["model"] as? String) ?? (body["name"] as? String) ?? ""
        let stream = body["stream"] as? Bool ?? true
        if stream {
            guard HTTPResponse.beginChunked(fd, contentType: "application/x-ndjson") else { return }
            HTTPResponse.chunk(fd, jsonData(["status": "pulling \(id)"]) + Data([10]))
            do {
                _ = try store.resolve(id)
                HTTPResponse.chunk(fd, jsonData(["status": "success"]) + Data([10]))
            } catch {
                HTTPResponse.chunk(fd, jsonData(["error": "\(error)"]) + Data([10]))
            }
            HTTPResponse.endChunked(fd)
        } else {
            _ = try store.resolve(id)
            HTTPResponse.json(fd, ["status": "success"])
        }
    }

    // MARK: Helpers

    private func openAIModel(_ model: LocalModel) -> [String: Any] {
        ["id": model.id, "object": "model", "created": Int(model.modified.timeIntervalSince1970), "owned_by": "mdock",
         "size": model.size, "loaded": pool.loaded.contains { $0.model.id == model.id }]
    }

    private func ollamaModel(_ model: LocalModel) -> [String: Any] {
        ["name": model.id, "model": model.id, "modified_at": iso(model.modified), "size": model.size,
         "digest": stableDigest("\(model.id):\(model.size)"),
         "details": ["format": "gguf", "family": "", "families": NSNull(), "parameter_size": "", "quantization_level": ""]]
    }

    private func applyOptions(_ body: [String: Any], to out: inout [String: Any]) {
        let options = body["options"] as? [String: Any] ?? [:]
        let mapping = ["temperature": "temperature", "top_p": "top_p", "top_k": "top_k", "min_p": "min_p",
                       "seed": "seed", "stop": "stop", "repeat_penalty": "repeat_penalty",
                       "presence_penalty": "presence_penalty", "frequency_penalty": "frequency_penalty"]
        for (from, to) in mapping { if let value = options[from] { out[to] = value } }
        if let n = options["num_predict"] as? Int, n >= 0 { out["max_tokens"] = n }
        if let format = body["format"] as? String, format == "json" {
            out["response_format"] = ["type": "json_object"]
        } else if let schema = body["format"] as? [String: Any] {
            out["response_format"] = ["type": "json_schema", "json_schema": ["name": "response", "schema": schema]]
        }
        if let think = body["think"] as? Bool { out["chat_template_kwargs"] = ["enable_thinking": think] }
    }

    /// Ollama messages carry tool-call arguments as objects; OpenAI wants JSON strings.
    private func openAIMessage(_ message: [String: Any]) -> [String: Any] {
        var out = message
        out.removeValue(forKey: "images")
        out.removeValue(forKey: "thinking")
        if let calls = message["tool_calls"] as? [[String: Any]] {
            out["tool_calls"] = calls.enumerated().map { index, call -> [String: Any] in
                let function = call["function"] as? [String: Any] ?? [:]
                var arguments = function["arguments"] ?? [:]
                if !(arguments is String) { arguments = String(decoding: jsonData(arguments), as: UTF8.self) }
                return ["id": call["id"] as? String ?? "call_\(index)", "type": "function",
                        "function": ["name": function["name"] ?? "", "arguments": arguments]]
            }
        }
        return out
    }

    private func ollamaToolCalls(_ calls: [[String: Any]]) -> [[String: Any]] {
        calls.map { call in
            let function = call["function"] as? [String: Any] ?? [:]
            return ["function": ["name": function["name"] ?? "", "arguments": decodeArguments(function["arguments"] as? String ?? "{}")]]
        }
    }

    private func decodeArguments(_ text: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [String: Any]()
    }
}

func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// FNV-1a: a stable stand-in for Ollama's content digests.
func stableDigest(_ text: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return String(format: "%016llx", hash)
}
