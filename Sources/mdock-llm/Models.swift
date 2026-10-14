import Foundation

/// A GGUF file on disk.
struct LocalModel {
    var id: String          // file name without .gguf
    var url: URL
    var size: Int64
    var modified: Date
}

/// The few GGUF header values needed to size a model and pick server flags.
struct GGUFInfo {
    var architecture = ""
    var blockCount = 0
    var contextLength = 0
    var embeddingLength = 0
    var headCount = 0
    var headCountKV = 0
    var keyLength = 0
    var valueLength = 0
    var hasPoolingType = false

    /// Bytes of f16 K+V cache per token of context.
    var kvBytesPerToken: Int {
        let heads = headCountKV > 0 ? headCountKV : headCount
        let headDim = headCount > 0 ? embeddingLength / headCount : 0
        let k = keyLength > 0 ? keyLength : headDim
        let v = valueLength > 0 ? valueLength : headDim
        return blockCount * heads * (k + v) * 2
    }

    /// Parses the key/value section. Large arrays (the vocabulary) are skipped, not decoded.
    static func read(_ url: URL) -> GGUFInfo? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        var cursor = 0
        func take(_ n: Int) -> Data? {
            guard cursor + n <= data.count else { return nil }
            defer { cursor += n }
            return data.subdata(in: cursor..<(cursor + n))
        }
        func u32() -> UInt32? { take(4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } } }
        func u64() -> UInt64? { take(8).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } } }
        func string() -> String? {
            guard let n = u64(), n < 1 << 20, let bytes = take(Int(n)) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
        let scalarSize: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
        func integer(_ type: UInt32) -> Int? {
            switch type {
            case 0, 1, 7: return take(1).map { Int($0[$0.startIndex]) }
            case 2, 3: return take(2).map { Int($0.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }) }
            case 4: return u32().map { Int($0) }
            case 5: return u32().map { Int(Int32(bitPattern: $0)) }
            case 10, 11: return u64().map { Int(truncatingIfNeeded: $0) }
            default: return nil
            }
        }
        func skip(_ type: UInt32) -> Bool {
            if let size = scalarSize[type] { return take(size) != nil }
            if type == 8 { return string() != nil }
            if type == 9 {
                guard let inner = u32(), let count = u64() else { return false }
                if let size = scalarSize[inner] {
                    cursor += Int(count) * size
                    return cursor <= data.count
                }
                for _ in 0..<count { if !skip(inner) { return false } }
                return true
            }
            return false
        }

        guard take(4) == Data("GGUF".utf8), let version = u32(), version >= 2,
              u64() != nil, let kvCount = u64() else { return nil }
        var info = GGUFInfo()
        var ints: [String: Int] = [:]
        for _ in 0..<kvCount {
            guard let key = string(), let type = u32() else { return nil }
            if key == "general.architecture", type == 8 {
                guard let value = string() else { return nil }
                info.architecture = value
            } else if type <= 5 || type == 10 || type == 11 {
                guard let value = integer(type) else { return nil }
                ints[key] = value
            } else if key.hasSuffix(".pooling_type") {
                info.hasPoolingType = true
                guard skip(type) else { return nil }
            } else {
                guard skip(type) else { return nil }
            }
        }
        let a = info.architecture
        info.blockCount = ints["\(a).block_count"] ?? 0
        info.contextLength = ints["\(a).context_length"] ?? 0
        info.embeddingLength = ints["\(a).embedding_length"] ?? 0
        info.headCount = ints["\(a).attention.head_count"] ?? 0
        info.headCountKV = ints["\(a).attention.head_count_kv"] ?? 0
        info.keyLength = ints["\(a).attention.key_length"] ?? 0
        info.valueLength = ints["\(a).attention.value_length"] ?? 0
        if ints["\(a).pooling_type"] != nil { info.hasPoolingType = true }
        return info
    }
}

/// Models in one directory, plus on-demand downloads from Hugging Face.
final class ModelStore {
    let directory: URL
    private let lock = NSLock()
    private var downloads: [String: DispatchGroup] = [:]

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func list() -> [LocalModel] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "gguf" }
            .filter { !Self.isExtraShard($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix("mmproj") }
            .compactMap { url in
                // Resolve symlinks for size and date.
                let real = url.resolvingSymlinksInPath()
                guard let values = try? real.resourceValues(forKeys: Set(keys)) else { return nil }
                return LocalModel(id: String(url.lastPathComponent.dropLast(5)), url: url,
                                  size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? Date())
            }
            .sorted { $0.id < $1.id }
    }

    /// Split GGUFs ("-00002-of-00003.gguf") are loaded through their first shard only.
    static func isExtraShard(_ name: String) -> Bool {
        guard let range = name.range(of: #"-(\d{5})-of-\d{5}\.gguf$"#, options: .regularExpression) else { return false }
        return !name[range].hasPrefix("-00001-")
    }

    func find(_ id: String) -> LocalModel? {
        let name = id.hasSuffix(".gguf") ? String(id.dropLast(5)) : id
        let models = list()
        return models.first { $0.id == name } ?? models.first { $0.id.lowercased() == name.lowercased() }
    }

    /// Resolves a model id: a local file name, or `owner/repo:file.gguf` / `owner/repo[:QUANT]`
    /// from Hugging Face (downloaded once into the models directory).
    func resolve(_ id: String) throws -> LocalModel {
        if let model = find(id) { return model }
        guard let ref = HFRef(id) else {
            throw LLMError(description: "model '\(id)' not found in \(directory.path) "
                + "(use a file name from /v1/models or a Hugging Face id like owner/repo:file.gguf)", status: 404)
        }
        let file = try ref.file ?? pickFile(ref)
        let local = directory.appendingPathComponent((file as NSString).lastPathComponent)
        if let model = find(local.lastPathComponent) { return model }
        try download(repo: ref.repo, file: file, to: local)
        guard let model = find(local.lastPathComponent) else {
            throw LLMError(description: "download of \(id) produced no model")
        }
        return model
    }

    struct HFRef {
        var repo: String
        var file: String?
        var quant: String

        init?(_ id: String) {
            let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
            let repo = parts[0].replacingOccurrences(of: "hf.co/", with: "")
                .replacingOccurrences(of: "huggingface.co/", with: "")
            let pieces = repo.split(separator: "/")
            guard pieces.count == 2, pieces.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }),
                  repo.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }) else { return nil }
            self.repo = repo
            if parts.count == 2, parts[1].lowercased().hasSuffix(".gguf") {
                guard !parts[1].contains(".."), !parts[1].hasPrefix("/") else { return nil }
                file = parts[1]
                quant = ""
            } else {
                quant = parts.count == 2 ? parts[1] : "Q4_K_M"
            }
        }
    }

    private static func authorize(_ request: inout URLRequest) {
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Picks the GGUF in a repo whose name contains the quant tag (single file or first shard).
    private func pickFile(_ ref: HFRef) throws -> String {
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models/\(ref.repo)/tree/main?recursive=true")!)
        Self.authorize(&request)
        let (data, status) = try fetch(request)
        guard status == 200, let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LLMError(description: "Hugging Face repo \(ref.repo): HTTP \(status)", status: status == 404 ? 404 : 502)
        }
        let ggufs = entries.compactMap { $0["path"] as? String }
            .filter { $0.lowercased().hasSuffix(".gguf") && !$0.lowercased().contains("mmproj") && !Self.isExtraShard($0) }
        let tag = ref.quant.lowercased()
        guard let file = ggufs.first(where: { $0.lowercased().contains(tag) }) else {
            throw LLMError(description: "no \(ref.quant) GGUF in \(ref.repo); available: \(ggufs.joined(separator: ", "))", status: 404)
        }
        if file.range(of: #"-00001-of-\d{5}\.gguf$"#, options: .regularExpression) != nil {
            throw LLMError(description: "\(file) is split; download its shards into \(directory.path) manually", status: 400)
        }
        return file
    }

    private func fetch(_ request: URLRequest) throws -> (Data, Int) {
        var result: Result<(Data, Int), Error> = .failure(LLMError(description: "no response"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) } else {
                result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    /// Downloads one file; concurrent requests for the same file wait for the first download.
    private func download(repo: String, file: String, to destination: URL) throws {
        let key = destination.lastPathComponent
        lock.lock()
        if let running = downloads[key] {
            lock.unlock()
            running.wait()
            return
        }
        let group = DispatchGroup()
        group.enter()
        downloads[key] = group
        lock.unlock()
        defer {
            lock.withLock { downloads[key] = nil }
            group.leave()
        }

        let encoded = file.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        var request = URLRequest(url: URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)")!)
        Self.authorize(&request)
        log("downloading \(repo)/\(file)")
        var result: Result<Void, Error> = .success(())
        let done = DispatchSemaphore(value: 0)
        let partial = destination.appendingPathExtension("part")
        let task = URLSession.shared.downloadTask(with: request) { tmp, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let tmp else {
                result = .failure(LLMError(description: "download \(repo)/\(file): HTTP \(status)", status: status == 404 ? 404 : 502))
                return
            }
            do {
                try? FileManager.default.removeItem(at: partial)
                try FileManager.default.moveItem(at: tmp, to: partial)
            } catch { result = .failure(error) }
        }
        task.resume()
        done.wait()
        try result.get()
        guard GGUFInfo.read(partial) != nil else {
            try? FileManager.default.removeItem(at: partial)
            throw LLMError(description: "\(repo)/\(file) is not a valid GGUF file", status: 502)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        chmod(destination.path, 0o644)
        log("downloaded \(destination.lastPathComponent)")
    }
}
