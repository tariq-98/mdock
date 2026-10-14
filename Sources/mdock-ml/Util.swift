import Foundation

enum Log {
    private static let lock = NSLock()
    private static let formatter = ISO8601DateFormatter()

    static func info(_ message: String) {
        lock.withLock {
            FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
        }
    }
}

enum JSON {
    /// Replaces values JSONSerialization can't encode (NaN, infinities) with null.
    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues(sanitize)
        case let array as [Any]: return array.map(sanitize)
        case let b as Bool: return b
        case let n as NSNumber where isBool(n): return n
        // Shortest round-trip text, so 0.9851 doesn't print as 0.98509999999999998.
        case let d as Double:
            guard d.isFinite else { return NSNull() }
            return d == d.rounded() && abs(d) < 1e15 ? d as Any : NSDecimalNumber(string: d.description)
        case let f as Float:
            return f.isFinite ? NSDecimalNumber(string: f.description) : NSNull()
        default: return value
        }
    }

    static func string(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: sanitize(object), options: [.withoutEscapingSlashes, .fragmentsAllowed]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, !isBool(n) { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, !isBool(n) { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
}

/// Runs async work from a blocking connection thread.
func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task.detached {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

func milliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
}

func rounded(_ value: Double, _ places: Double = 2) -> Double {
    let scale = pow(10, places)
    return (value * scale).rounded() / scale
}

/// Paths under `~/.mdock/accel/ml`.
enum Paths {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdock/accel/ml")
    static let models = root.appendingPathComponent("models")
}
