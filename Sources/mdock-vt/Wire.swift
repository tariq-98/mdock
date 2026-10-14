import Foundation

/// Binary protocol shared with the guest VA-API driver (see accel/vaapi/PROTOCOL.md).
enum Wire {
    static let magic: UInt32 = 0x5456_444D  // "MDVT"
    static let version: UInt32 = 2
    static let headerSize = 16
    /// Replies carry the request op with this bit set, and the request's tag.
    static let replyBit: UInt16 = 0x8000
    /// `hello` flag: the driver can use a frame file.
    static let helloWantsFrameFile: UInt32 = 1
    /// `surfaceGet`/`surfacePut` flag and reply mode: pixels travel through the frame file.
    static let viaFrameFile: UInt32 = 1
    /// Frame files hold one picture: up to 8192×4352 P010, rounded to 4 KiB.
    static let frameFileSize = 8192 * 4352 * 3 + 4096

    enum Op: UInt16 {
        case hello = 1
        case surfaceCreate = 2
        case surfaceDestroy = 3
        case surfacePut = 4
        case surfaceGet = 5
        case decoderCreate = 6
        case decode = 7
        case contextDestroy = 8
        case encoderCreate = 9
        case encode = 10
        case encoderConfigure = 11
        case bench = 12
        case surfaceCopy = 13
        case process = 14
        case encoderFlush = 15
    }

    /// Reply status codes; the values match VAStatus so the driver can return them unchanged.
    enum Status: UInt32 {
        case ok = 0
        case operationFailed = 1
        case allocationFailed = 2
        case invalidSurface = 6
        case invalidContext = 5
        case unsupportedProfile = 12
        case invalidParameter = 18
        case decodingError = 0x17
        case encodingError = 0x18
    }

    enum Codec: UInt32 {
        case h264 = 1
        case hevc = 2
    }

    /// FourCCs as libva spells them.
    static let fourccNV12: UInt32 = 0x3231_564E  // 'NV12'
    static let fourccP010: UInt32 = 0x3031_3050  // 'P010'

    /// Capability bits returned by `hello`.
    struct Caps: OptionSet {
        let rawValue: UInt32
        static let h264Decode = Caps(rawValue: 1 << 0)
        static let hevcDecode = Caps(rawValue: 1 << 1)
        static let hevc10Decode = Caps(rawValue: 1 << 2)
        static let h264Encode = Caps(rawValue: 1 << 3)
        static let hevcEncode = Caps(rawValue: 1 << 4)
        static let hevc10Encode = Caps(rawValue: 1 << 5)
    }
}

struct WireError: Error {
    let status: Wire.Status
    let message: String
    init(_ status: Wire.Status, _ message: String) {
        self.status = status
        self.message = message
    }
}

/// Little-endian cursor over a request payload.
struct Reader {
    let base: UnsafeRawPointer
    let count: Int
    var offset = 0

    init(_ buffer: UnsafeRawBufferPointer) {
        base = buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!
        count = buffer.count
    }

    var remaining: Int { count - offset }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw WireError(.invalidParameter, "short payload") }
        let v = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        offset += 4
        return UInt32(littleEndian: v)
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func bytes(_ n: Int) throws -> UnsafeRawBufferPointer {
        guard n >= 0, remaining >= n else { throw WireError(.invalidParameter, "short payload") }
        defer { offset += n }
        return UnsafeRawBufferPointer(start: base + offset, count: n)
    }

    mutating func rest() -> UnsafeRawBufferPointer {
        defer { offset = count }
        return UnsafeRawBufferPointer(start: base + offset, count: remaining)
    }
}

/// Growable little-endian reply payload.
struct Writer {
    var data = [UInt8]()

    mutating func u32(_ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ bytes: UnsafeRawBufferPointer) { data.append(contentsOf: bytes) }
    mutating func append(_ bytes: Data) { data.append(contentsOf: bytes) }
}
