import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Core ML model store and runner: upload, compile, cache under `~/.mdock/accel/ml/models/<id>`, predict.
final class CoreMLService {
    private let lock = NSLock()
    private var loaded: [String: MLModel] = [:]
    private var order: [String] = []
    private let capacity = 6
    private let ciContext = CIContext()

    // MARK: routes

    func route(_ req: HTTPRequest, _ r: HTTPResponder, _ parts: [String]) throws {
        // parts after "/v1/coreml/models"
        switch (req.method, parts.count) {
        case ("GET", 0): r.json(200, ["object": "list", "data": try list()])
        case ("POST", 0): r.json(201, try upload(req))
        case ("GET", 1), ("HEAD", 1): r.json(200, try describe(parts[0]))
        case ("DELETE", 1): r.json(200, try delete(parts[0]))
        case ("POST", 2) where parts[1] == "predict": r.json(200, try predict(parts[0], try req.json()))
        case ("POST", 2) where parts[1] == "load":
            // Warm-up: the first load per compute-units setting compiles for the ANE/GPU and can be slow.
            let body = try req.json()
            let units = try Self.computeUnits(body["compute_units"] as? String ?? req.query["compute_units"] ?? "all")
            let (_, loadMs) = try model(parts[0], units: units)
            r.json(200, ["id": parts[0], "compute_units": Self.unitsName(units), "loaded": true,
                         "load_ms": loadMs.map { rounded($0) } ?? 0, "cached": loadMs == nil])
        case ("GET", 2) where parts[1] == "plan":
            r.json(200, try plan(parts[0], units: req.query["compute_units"] ?? "all", detail: req.query["detail"] == "1"))
        default: throw HTTPError(404, "no route for \(req.method) \(req.path)")
        }
    }

    // MARK: store

    private func directory(_ id: String) throws -> URL {
        guard id.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil, !id.hasPrefix(".") else {
            throw HTTPError(400, "invalid model id")
        }
        let dir = Paths.models.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.mlmodelc").path) else {
            throw HTTPError(404, "model \(id) not found", code: "model_not_found")
        }
        return dir
    }

    func list() throws -> [[String: Any]] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: Paths.models.path)) ?? []
        return ids.sorted().compactMap { id in
            let meta = Paths.models.appendingPathComponent(id).appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    func upload(_ req: HTTPRequest) throws -> [String: Any] {
        var name = req.query["name"]
        var filename = req.query["filename"] ?? req.headers["x-filename"]
        var payload: URL
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mdock-ml-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        if req.contentType.lowercased().hasPrefix("multipart/form-data") {
            let form = try Multipart.parse(try req.body(), contentType: req.contentType)
            guard let file = form.first(where: { $0.name == "file" || $0.name == "model" }) else {
                throw HTTPError(400, "multipart upload needs a 'file' part")
            }
            filename = file.filename ?? filename
            if name == nil, let n = form.first(where: { $0.name == "name" }) { name = String(decoding: n.data, as: UTF8.self) }
            payload = scratch.appendingPathComponent("payload")
            try file.data.write(to: payload)
        } else {
            payload = try req.bodyAsFile()
        }
        let header = (try? FileHandle(forReadingFrom: payload).read(upToCount: 4)) ?? Data()
        guard !header.isEmpty else { throw HTTPError(400, "empty upload") }

        // Locate the model inside the upload.
        var source: URL
        if header.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            let unpacked = scratch.appendingPathComponent("unzipped")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", payload.path, unpacked.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw HTTPError(400, "could not unzip the upload") }
            guard let found = Self.findModel(in: unpacked) else {
                throw HTTPError(400, "zip contains no .mlpackage, .mlmodelc or .mlmodel")
            }
            source = found
        } else {
            // A bare .mlmodel protobuf.
            source = scratch.appendingPathComponent("model.mlmodel")
            try FileManager.default.copyItem(at: payload, to: source)
        }
        let baseName = name ?? filename.map { ($0 as NSString).deletingPathExtension }
            ?? source.deletingPathExtension().lastPathComponent
        let id = try newID(baseName)

        let start = DispatchTime.now()
        var compiled: URL
        let kind = source.pathExtension
        if kind == "mlmodelc" {
            compiled = source
        } else {
            do {
                compiled = try blocking { try await MLModel.compileModel(at: source) }
            } catch {
                throw HTTPError(400, "Core ML compile failed: \(error.localizedDescription)", code: "compile_failed")
            }
        }
        let compileMs = milliseconds(since: start)
        let dir = Paths.models.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("model.mlmodelc")
        do {
            try FileManager.default.moveItem(at: compiled, to: dest)
        } catch {
            try FileManager.default.copyItem(at: compiled, to: dest)
            try? FileManager.default.removeItem(at: compiled)
        }
        // Validate by loading on the CPU.
        let model: MLModel
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: dest, configuration: config)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw HTTPError(400, "compiled model does not load: \(error.localizedDescription)", code: "load_failed")
        }
        var meta: [String: Any] = [
            "id": id, "object": "coreml.model", "name": baseName, "source_format": kind,
            "created": Int(Date().timeIntervalSince1970), "compile_ms": rounded(compileMs),
            "size_bytes": Self.size(of: dest),
            "inputs": model.modelDescription.inputDescriptionsByName.keys.sorted(),
            "outputs": model.modelDescription.outputDescriptionsByName.keys.sorted(),
        ]
        if let d = model.modelDescription.metadata[.description] as? String, !d.isEmpty { meta["description"] = d }
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("meta.json"))
        Log.info("coreml: stored \(id) (\(kind), compiled in \(Int(compileMs))ms)")
        // The first load per compute-units setting compiles for the ANE (seconds to minutes); start it now.
        let warm = req.query["warm"] ?? "all"
        if warm != "none", let units = try? Self.computeUnits(warm) {
            meta["warming"] = Self.unitsName(units)
            Thread.detachNewThread { [self] in _ = try? self.model(id, units: units) }
        }
        return meta
    }

    private func newID(_ base: String) throws -> String {
        var cleaned = base.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        cleaned = String(cleaned.drop(while: { $0 == "." || $0 == "-" }).prefix(60))
        if cleaned.isEmpty { cleaned = "model" }
        try FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)
        var id = cleaned
        var n = 2
        while FileManager.default.fileExists(atPath: Paths.models.appendingPathComponent(id).path) {
            id = "\(cleaned)-\(n)"
            n += 1
        }
        return id
    }

    private static func findModel(in root: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var candidates: [URL] = []
        for case let url as URL in walker {
            if url.path.contains("__MACOSX") { continue }
            switch url.pathExtension {
            case "mlmodelc", "mlpackage":
                candidates.append(url)
                walker.skipDescendants()
            case "mlmodel": candidates.append(url)
            default: break
            }
        }
        let rank = ["mlmodelc": 0, "mlpackage": 1, "mlmodel": 2]
        return candidates.min { rank[$0.pathExtension]! < rank[$1.pathExtension]! }
    }

    private static func size(of url: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in walker { total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 }
        return total
    }

    func delete(_ id: String) throws -> [String: Any] {
        let dir = try directory(id)
        lock.withLock {
            for key in loaded.keys where key.hasPrefix(id + "|") { loaded[key] = nil }
            order.removeAll { $0.hasPrefix(id + "|") }
        }
        try FileManager.default.removeItem(at: dir)
        return ["id": id, "object": "coreml.model", "deleted": true]
    }

    // MARK: loading

    static func computeUnits(_ name: String) throws -> MLComputeUnits {
        switch name.lowercased().replacingOccurrences(of: "_", with: "") {
        case "all", "": return .all
        case "cpuandneuralengine", "ane", "neuralengine", "cpuandne": return .cpuAndNeuralEngine
        case "cpuandgpu", "gpu": return .cpuAndGPU
        case "cpuonly", "cpu": return .cpuOnly
        default: throw HTTPError(400, "compute_units must be all, cpuAndNeuralEngine, cpuAndGPU or cpuOnly")
        }
    }

    static func unitsName(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "cpuOnly"
        case .cpuAndGPU: return "cpuAndGPU"
        case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
        default: return "all"
        }
    }

    /// Returns a loaded model from the LRU (keyed by id and compute units) and the load time if it was loaded now.
    private func model(_ id: String, units: MLComputeUnits) throws -> (MLModel, Double?) {
        let key = "\(id)|\(units.rawValue)"
        if let model = lock.withLock({ () -> MLModel? in
            guard let model = loaded[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return model
        }) { return (model, nil) }
        let url = try directory(id).appendingPathComponent("model.mlmodelc")
        let config = MLModelConfiguration()
        config.computeUnits = units
        let start = DispatchTime.now()
        let model: MLModel
        do { model = try MLModel(contentsOf: url, configuration: config) } catch {
            throw HTTPError(500, "load failed: \(error.localizedDescription)", code: "load_failed")
        }
        let loadMs = milliseconds(since: start)
        lock.withLock {
            loaded[key] = model
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > capacity { loaded[order.removeFirst()] = nil }
        }
        Log.info("coreml: loaded \(id) [\(Self.unitsName(units))] in \(Int(loadMs))ms")
        return (model, loadMs)
    }

    // MARK: describe

    func describe(_ id: String) throws -> [String: Any] {
        let (model, _) = try model(id, units: .cpuOnly)
        let d = model.modelDescription
        var result = (try? JSONSerialization.jsonObject(with: Data(contentsOf: directory(id).appendingPathComponent("meta.json")))
            as? [String: Any]) ?? ["id": id]
        result["inputs"] = d.inputDescriptionsByName.values.sorted { $0.name < $1.name }.map(Self.describe)
        result["outputs"] = d.outputDescriptionsByName.values.sorted { $0.name < $1.name }.map(Self.describe)
        if #available(macOS 15.0, *), !d.stateDescriptionsByName.isEmpty {
            result["states"] = d.stateDescriptionsByName.values.sorted { $0.name < $1.name }.map(Self.describe)
        }
        var metadata: [String: Any] = [:]
        for (key, value) in d.metadata {
            switch value {
            case let s as String where !s.isEmpty: metadata[key.rawValue] = s
            case let dict as [String: String] where !dict.isEmpty: metadata[key.rawValue] = dict
            default: break
            }
        }
        result["metadata"] = metadata
        if let p = d.predictedFeatureName { result["predicted_feature"] = p }
        if let p = d.predictedProbabilitiesName { result["predicted_probabilities"] = p }
        if let labels = d.classLabels, !labels.isEmpty {
            result["class_labels_count"] = labels.count
            result["class_labels_sample"] = labels.prefix(10).map { "\($0)" }
        }
        return result
    }

    private static func dtypeName(_ t: MLMultiArrayDataType) -> String {
        switch t {
        case .float16: return "float16"
        case .float32: return "float32"
        case .double: return "float64"
        case .int32: return "int32"
        case .int8: return "int8"
        @unknown default: return "unknown(\(t.rawValue))"
        }
    }

    private static func pixelFormatName(_ format: OSType) -> String {
        switch format {
        case kCVPixelFormatType_32BGRA: return "BGRA"
        case kCVPixelFormatType_32ARGB: return "ARGB"
        case kCVPixelFormatType_OneComponent8: return "Gray8"
        case kCVPixelFormatType_OneComponent16Half: return "Gray16Half"
        default: return String(format: "0x%08x", format)
        }
    }

    static func describe(_ f: MLFeatureDescription) -> [String: Any] {
        var out: [String: Any] = ["name": f.name, "optional": f.isOptional]
        switch f.type {
        case .multiArray:
            out["type"] = "multiArray"
            if let c = f.multiArrayConstraint {
                out["shape"] = c.shape.map(\.intValue)
                out["dtype"] = dtypeName(c.dataType)
                switch c.shapeConstraint.type {
                case .enumerated: out["enumerated_shapes"] = c.shapeConstraint.enumeratedShapes.map { $0.map(\.intValue) }
                case .range: out["shape_ranges"] = c.shapeConstraint.sizeRangeForDimension.map {
                    let r = $0.rangeValue
                    return [r.location, r.location + r.length == Int.max ? -1 : r.location + r.length]
                }
                default: break
                }
            }
        case .image:
            out["type"] = "image"
            if let c = f.imageConstraint {
                out["width"] = c.pixelsWide
                out["height"] = c.pixelsHigh
                out["pixel_format"] = pixelFormatName(c.pixelFormatType)
            }
        case .string: out["type"] = "string"
        case .int64: out["type"] = "int64"
        case .double: out["type"] = "double"
        case .dictionary:
            out["type"] = "dictionary"
            out["key_type"] = f.dictionaryConstraint?.keyType == .string ? "string" : "int64"
        case .sequence:
            out["type"] = "sequence"
            out["element_type"] = f.sequenceConstraint?.valueDescription.type == .string ? "string" : "int64"
        case .state: out["type"] = "state"
        default: out["type"] = "invalid"
        }
        return out
    }

    // MARK: predict

    func predict(_ id: String, _ body: [String: Any]) throws -> [String: Any] {
        let units = try Self.computeUnits(body["compute_units"] as? String ?? "all")
        let (model, loadMs) = try model(id, units: units)
        guard let inputs = body["inputs"] as? [String: Any] else { throw HTTPError(400, "inputs must be an object") }
        let crop = body["image_crop"] as? String ?? "center"
        let start = DispatchTime.now()
        var features: [String: MLFeatureValue] = [:]
        for (name, description) in model.modelDescription.inputDescriptionsByName {
            guard let value = inputs[name] else {
                if description.isOptional { continue }
                throw HTTPError(400, "missing input '\(name)': \(JSON.string(Self.describe(description)))")
            }
            features[name] = try feature(value, description, crop: crop)
        }
        for key in inputs.keys where model.modelDescription.inputDescriptionsByName[key] == nil {
            throw HTTPError(400, "unknown input '\(key)'; model inputs are \(model.modelDescription.inputDescriptionsByName.keys.sorted())")
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: features)
        let prepareMs = milliseconds(since: start)

        let runs = max(1, min(JSON.int(body["repeat"]) ?? 1, 1000))
        var times: [Double] = []
        var output: MLFeatureProvider?
        for _ in 0..<runs {
            let t = DispatchTime.now()
            do { output = try model.prediction(from: provider) } catch {
                throw HTTPError(400, "prediction failed: \(error.localizedDescription)", code: "prediction_failed")
            }
            times.append(milliseconds(since: t))
        }
        let encodeStart = DispatchTime.now()
        let format = body["output_format"] as? String ?? "nested"
        let topK = JSON.int(body["top_k"]) ?? 5
        var outputs: [String: Any] = [:]
        for name in output!.featureNames {
            guard let value = output!.featureValue(for: name) else { continue }
            outputs[name] = try encode(value, base64: format == "base64", topK: topK)
        }
        var timing: [String: Any] = [
            "compute_units": Self.unitsName(units),
            "prepare_ms": rounded(prepareMs, 3),
            "predict_ms": rounded(times[0], 3),
            "encode_ms": rounded(milliseconds(since: encodeStart), 3),
        ]
        if let loadMs { timing["load_ms"] = rounded(loadMs) }
        if runs > 1 {
            let steady = times.count > 2 ? Array(times.dropFirst()) : times
            let sorted = steady.sorted()
            timing["runs"] = runs
            timing["first_ms"] = rounded(times[0], 3)
            timing["min_ms"] = rounded(sorted.first!, 3)
            timing["median_ms"] = rounded(sorted[sorted.count / 2], 3)
            timing["mean_ms"] = rounded(sorted.reduce(0, +) / Double(sorted.count), 3)
            timing["p90_ms"] = rounded(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))], 3)
        }
        return ["id": id, "object": "coreml.prediction", "outputs": outputs, "timing": timing]
    }

    private func feature(_ value: Any, _ description: MLFeatureDescription, crop: String) throws -> MLFeatureValue {
        let name = description.name
        switch description.type {
        case .multiArray:
            return MLFeatureValue(multiArray: try multiArray(value, description.multiArrayConstraint, name: name))
        case .image:
            guard let c = description.imageConstraint else { throw HTTPError(400, "\(name): image has no constraint") }
            var b64: String?
            if let s = value as? String { b64 = s }
            if let d = value as? [String: Any] { b64 = d["base64"] as? String ?? d["data"] as? String }
            guard var text = b64 else { throw HTTPError(400, "\(name): image must be a base64 PNG/JPEG string") }
            if text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") { text = String(text[text.index(after: comma)...]) }
            guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw HTTPError(400, "\(name): could not decode the image")
            }
            let option: VNImageCropAndScaleOption = crop == "fill" ? .scaleFill : crop == "fit" ? .scaleFit : .centerCrop
            do {
                return try MLFeatureValue(cgImage: image, constraint: c,
                                          options: [.cropAndScale: option.rawValue])
            } catch { throw HTTPError(400, "\(name): \(error.localizedDescription)") }
        case .string:
            guard let s = value as? String else { throw HTTPError(400, "\(name): expected a string") }
            return MLFeatureValue(string: s)
        case .int64:
            guard let i = JSON.int(value) else { throw HTTPError(400, "\(name): expected an integer") }
            return MLFeatureValue(int64: Int64(i))
        case .double:
            guard let d = JSON.double(value) else { throw HTTPError(400, "\(name): expected a number") }
            return MLFeatureValue(double: d)
        case .dictionary:
            guard let d = value as? [String: Any] else { throw HTTPError(400, "\(name): expected an object") }
            var dict: [AnyHashable: NSNumber] = [:]
            let intKeys = description.dictionaryConstraint?.keyType == .int64
            for (k, v) in d {
                guard let n = JSON.double(v) else { throw HTTPError(400, "\(name): dictionary values must be numbers") }
                if intKeys { dict[Int64(k) ?? 0] = NSNumber(value: n) } else { dict[k] = NSNumber(value: n) }
            }
            do { return try MLFeatureValue(dictionary: dict) } catch { throw HTTPError(400, "\(name): \(error.localizedDescription)") }
        case .sequence:
            if let s = value as? [String] { return MLFeatureValue(sequence: MLSequence(strings: s)) }
            if let a = value as? [Any] { return MLFeatureValue(sequence: MLSequence(int64s: a.compactMap(JSON.int).map { NSNumber(value: $0) })) }
            throw HTTPError(400, "\(name): expected an array")
        default:
            throw HTTPError(400, "\(name): unsupported input type")
        }
    }

    /// Builds a multiarray from nested arrays, `{shape, values}`, or `{shape, data: base64, dtype}`.
    private func multiArray(_ value: Any, _ constraint: MLMultiArrayConstraint?, name: String) throws -> MLMultiArray {
        var values: [Double] = []
        var shape: [Int] = []
        if let dict = value as? [String: Any] {
            shape = (dict["shape"] as? [Any])?.compactMap(JSON.int) ?? []
            if let b64 = dict["data"] as? String ?? dict["base64"] as? String {
                guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                    throw HTTPError(400, "\(name): bad base64")
                }
                values = try Self.decode(data, dtype: dict["dtype"] as? String ?? "float32", name: name)
            } else if let flat = dict["values"] as? [Any] {
                values = try flat.map { guard let d = JSON.double($0) else { throw HTTPError(400, "\(name): non-numeric value") }; return d }
            } else {
                throw HTTPError(400, "\(name): multiarray object needs 'data' (base64) or 'values'")
            }
        } else if let nested = value as? [Any] {
            shape = try Self.flatten(nested, into: &values, name: name)
        } else if let d = JSON.double(value) {
            values = [d]
            shape = [1]
        } else {
            throw HTTPError(400, "\(name): expected a nested array or {shape, data|values}")
        }
        let expected = constraint?.shape.map(\.intValue) ?? []
        let flexible = constraint.map {
            $0.shapeConstraint.type == .range || $0.shapeConstraint.enumeratedShapes.count > 1
        } ?? false
        if shape.isEmpty || (!flexible && !expected.isEmpty && shape != expected && shape.reduce(1, *) == expected.reduce(1, *)) {
            // Reshape flat data to the model's fixed shape.
            if !expected.isEmpty && values.count == expected.reduce(1, *) { shape = expected }
        }
        if shape.isEmpty { shape = [values.count] }
        guard shape.reduce(1, *) == values.count else {
            throw HTTPError(400, "\(name): shape \(shape) does not match \(values.count) values")
        }
        if !flexible, !expected.isEmpty, shape != expected {
            throw HTTPError(400, "\(name): shape \(shape) but the model expects \(expected)")
        }
        let dtype = constraint?.dataType ?? .float32
        let array: MLMultiArray
        do { array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: dtype) } catch {
            throw HTTPError(400, "\(name): \(error.localizedDescription)")
        }
        let strides = array.strides.map(\.intValue)
        let contiguous = Self.contiguousStrides(shape)
        array.withUnsafeMutableBytes { raw, _ in
            func offset(_ i: Int) -> Int {
                if strides == contiguous { return i }
                var rest = i, off = 0
                for d in 0..<shape.count { off += (rest / contiguous[d]) * strides[d]; rest %= contiguous[d] }
                return off
            }
            switch dtype {
            case .float32:
                let p = raw.bindMemory(to: Float.self)
                for i in values.indices { p[offset(i)] = Float(values[i]) }
            case .float16:
                let p = raw.bindMemory(to: Float16.self)
                for i in values.indices { p[offset(i)] = Float16(values[i]) }
            case .double:
                let p = raw.bindMemory(to: Double.self)
                for i in values.indices { p[offset(i)] = values[i] }
            case .int32:
                let p = raw.bindMemory(to: Int32.self)
                for i in values.indices { p[offset(i)] = Int32(clamping: Int(values[i].rounded())) }
            default:
                let p = raw.bindMemory(to: Int8.self)
                for i in values.indices { p[offset(i)] = Int8(clamping: Int(values[i].rounded())) }
            }
        }
        return array
    }

    private static func contiguousStrides(_ shape: [Int]) -> [Int] {
        var strides = [Int](repeating: 1, count: shape.count)
        for d in stride(from: shape.count - 2, through: 0, by: -1) { strides[d] = strides[d + 1] * shape[d + 1] }
        return strides
    }

    private static func decode(_ data: Data, dtype: String, name: String) throws -> [Double] {
        func load<T>(_ type: T.Type, _ convert: (T) -> Double) throws -> [Double] {
            guard data.count % MemoryLayout<T>.size == 0 else {
                throw HTTPError(400, "\(name): \(data.count) bytes is not a multiple of the \(dtype) size")
            }
            return data.withUnsafeBytes { raw in
                (0..<data.count / MemoryLayout<T>.size).map { convert(raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.size, as: T.self)) }
            }
        }
        switch dtype.lowercased() {
        case "float32", "f32", "float": return try load(Float.self) { Double($0) }
        case "float16", "f16", "half": return try load(Float16.self) { Double($0) }
        case "float64", "f64", "double": return try load(Double.self) { $0 }
        case "int32", "i32": return try load(Int32.self) { Double($0) }
        case "int64", "i64": return try load(Int64.self) { Double($0) }
        case "uint8", "u8": return try load(UInt8.self) { Double($0) }
        default: throw HTTPError(400, "\(name): unsupported dtype \(dtype)")
        }
    }

    private static func flatten(_ nested: [Any], into values: inout [Double], name: String) throws -> [Int] {
        guard let first = nested.first else { return [0] }
        if first is [Any] {
            var inner: [Int]?
            for element in nested {
                guard let sub = element as? [Any] else { throw HTTPError(400, "\(name): ragged nested array") }
                let shape = try flatten(sub, into: &values, name: name)
                if let inner, inner != shape { throw HTTPError(400, "\(name): ragged nested array") }
                inner = shape
            }
            return [nested.count] + (inner ?? [])
        }
        for element in nested {
            guard let d = JSON.double(element) else { throw HTTPError(400, "\(name): non-numeric value") }
            values.append(d)
        }
        return [nested.count]
    }

    private func encode(_ value: MLFeatureValue, base64: Bool, topK: Int) throws -> Any {
        switch value.type {
        case .multiArray:
            guard let array = value.multiArrayValue else { return NSNull() }
            let shape = array.shape.map(\.intValue)
            let floats = Self.floats(array)
            if base64 {
                let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
                return ["type": "multiArray", "shape": shape, "dtype": "float32", "data": data.base64EncodedString()]
            }
            return ["type": "multiArray", "shape": shape, "dtype": Self.dtypeName(array.dataType),
                    "data": Self.nest(floats, shape: shape)]
        case .dictionary:
            let dict = value.dictionaryValue
            let pairs = dict.map { (label: "\($0.key)", p: $0.value.doubleValue) }.sorted { $0.p > $1.p }
            if topK > 0 && pairs.count > topK {
                return ["type": "dictionary", "count": pairs.count,
                        "top": pairs.prefix(topK).map { ["label": $0.label, "probability": $0.p] }]
            }
            return ["type": "dictionary", "values": Dictionary(pairs.map { ($0.label, $0.p) }, uniquingKeysWith: { a, _ in a })]
        case .string: return value.stringValue
        case .int64: return value.int64Value
        case .double: return value.doubleValue
        case .image:
            guard let buffer = value.imageBufferValue else { return NSNull() }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let png = ciContext.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
                return NSNull()
            }
            return ["type": "image", "format": "png", "width": CVPixelBufferGetWidth(buffer),
                    "height": CVPixelBufferGetHeight(buffer), "data": png.base64EncodedString()]
        case .sequence:
            guard let seq = value.sequenceValue else { return NSNull() }
            return seq.type == .string ? seq.stringValues : seq.int64Values.map(\.int64Value)
        default: return NSNull()
        }
    }

    /// Reads any multiarray into C-ordered floats, honouring strides.
    private static func floats(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let contiguous = contiguousStrides(shape)
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        array.withUnsafeBytes { raw in
            func offset(_ i: Int) -> Int {
                if strides == contiguous { return i }
                var rest = i, off = 0
                for d in 0..<shape.count { off += (rest / contiguous[d]) * strides[d]; rest %= contiguous[d] }
                return off
            }
            switch array.dataType {
            case .float32: let p = raw.bindMemory(to: Float.self); for i in 0..<count { out[i] = p[offset(i)] }
            case .float16: let p = raw.bindMemory(to: Float16.self); for i in 0..<count { out[i] = Float(p[offset(i)]) }
            case .double: let p = raw.bindMemory(to: Double.self); for i in 0..<count { out[i] = Float(p[offset(i)]) }
            case .int32: let p = raw.bindMemory(to: Int32.self); for i in 0..<count { out[i] = Float(p[offset(i)]) }
            default: let p = raw.bindMemory(to: Int8.self); for i in 0..<count { out[i] = Float(p[offset(i)]) }
            }
        }
        return out
    }

    private static func nest(_ values: [Float], shape: [Int]) -> Any {
        guard shape.count > 1 else { return values }
        let inner = Array(shape.dropFirst())
        let size = inner.reduce(1, *)
        return (0..<shape[0]).map { nest(Array(values[$0 * size..<($0 + 1) * size]), shape: inner) }
    }

    // MARK: compute plan

    /// Where Core ML plans to run each operation for the given compute units.
    func plan(_ id: String, units: String, detail: Bool) throws -> [String: Any] {
        guard #available(macOS 14.4, *) else { throw HTTPError(501, "compute plans need macOS 14.4") }
        let computeUnits = try Self.computeUnits(units)
        let url = try directory(id).appendingPathComponent("model.mlmodelc")
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let plan = try blocking { try await MLComputePlan.load(contentsOf: url, configuration: config) }
        var counts: [String: Int] = [:]
        var cost: [String: Double] = [:]
        var ops: [[String: Any]] = []

        func device(_ d: MLComputeDevice) -> String {
            switch d {
            case .cpu: return "cpu"
            case .gpu: return "gpu"
            case .neuralEngine: return "neuralEngine"
            @unknown default: return "other"
            }
        }
        func walk(_ operations: [MLModelStructure.Program.Operation]) {
            for op in operations {
                for block in op.blocks { walk(block.operations) }
                guard let usage = plan.deviceUsage(for: op) else { continue }
                let d = device(usage.preferred)
                counts[d, default: 0] += 1
                let weight = plan.estimatedCost(of: op)?.weight ?? 0
                cost[d, default: 0] += weight
                if detail {
                    ops.append(["op": op.operatorName, "preferred": d, "supported": usage.supported.map(device),
                                "cost": weight])
                }
            }
        }
        func walk(_ structure: MLModelStructure) {
            switch structure {
            case .program(let program):
                for function in program.functions.values { walk(function.block.operations) }
            case .neuralNetwork(let network):
                for layer in network.layers {
                    guard let usage = plan.deviceUsage(for: layer) else { continue }
                    counts[device(usage.preferred), default: 0] += 1
                    if detail { ops.append(["layer": layer.name, "type": layer.type, "preferred": device(usage.preferred)]) }
                }
            case .pipeline(let pipeline):
                for sub in pipeline.subModels { walk(sub) }
            default: break
            }
        }
        walk(plan.modelStructure)
        var result: [String: Any] = [
            "id": id, "compute_units": Self.unitsName(computeUnits),
            "operations": counts.values.reduce(0, +), "preferred_device_counts": counts,
            "estimated_cost_share": cost.mapValues { rounded($0, 4) },
        ]
        if detail { result["detail"] = ops }
        return result
    }

    // MARK: capabilities

    static func devices() -> [[String: Any]] {
        MLComputeDevice.allComputeDevices.map { device in
            switch device {
            case .cpu: return ["type": "cpu"]
            case .gpu(let gpu): return ["type": "gpu", "name": gpu.metalDevice.name]
            case .neuralEngine(let ane): return ["type": "neuralEngine", "cores": ane.totalCoreCount]
            @unknown default: return ["type": "other"]
            }
        }
    }
}

/// Minimal multipart/form-data parser.
enum Multipart {
    struct Part {
        var name: String
        var filename: String?
        var contentType: String?
        var data: Data
    }

    static func parse(_ body: Data, contentType: String) throws -> [Part] {
        guard let range = contentType.range(of: "boundary=") else { throw HTTPError(400, "multipart without boundary") }
        var boundary = String(contentType[range.upperBound...])
        if let semi = boundary.firstIndex(of: ";") { boundary = String(boundary[..<semi]) }
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let delimiter = Data("--\(boundary)".utf8)
        let crlf = Data("\r\n".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var parts: [Part] = []
        guard var cursor = body.range(of: delimiter)?.upperBound else { throw HTTPError(400, "malformed multipart body") }
        while true {
            // After a delimiter: "--" ends, otherwise CRLF then headers.
            if body[cursor...].starts(with: Data("--".utf8)) { break }
            if body[cursor...].starts(with: crlf) { cursor += 2 }
            guard let headEnd = body.range(of: headerEnd, in: cursor..<body.endIndex) else { throw HTTPError(400, "malformed multipart part") }
            let headers = String(decoding: body[cursor..<headEnd.lowerBound], as: UTF8.self)
            let dataStart = headEnd.upperBound
            guard let next = body.range(of: crlf + delimiter, in: dataStart..<body.endIndex) else {
                throw HTTPError(400, "unterminated multipart part")
            }
            var part = Part(name: "", data: body.subdata(in: dataStart..<next.lowerBound))
            for line in headers.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("content-disposition:") {
                    part.name = param("name", in: line) ?? ""
                    part.filename = param("filename", in: line)
                } else if lower.hasPrefix("content-type:") {
                    part.contentType = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces)
                }
            }
            parts.append(part)
            cursor = next.upperBound
        }
        return parts
    }

    private static func param(_ key: String, in line: String) -> String? {
        for piece in line.split(separator: ";") {
            let kv = piece.trimmingCharacters(in: .whitespaces)
            guard kv.lowercased().hasPrefix(key + "=") else { continue }
            return String(kv.dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    static func field(_ parts: [Part], _ name: String) -> String? {
        parts.first { $0.name == name }.map { String(decoding: $0.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
