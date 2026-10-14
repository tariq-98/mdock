import CoreVideo
import Foundation

/// A VA surface as the host sees it: a size, a format and, once something was decoded or uploaded
/// into it, the pixel buffer holding the picture.
final class Surface {
    let width: Int
    let height: Int
    let fourcc: UInt32
    var buffer: CVPixelBuffer?
    /// Decoder with a frame for this surface still in flight (its callback sets `buffer`).
    var decoding: Decoder?

    init(width: Int, height: Int, fourcc: UInt32) {
        self.width = width
        self.height = height
        self.fourcc = fourcc
    }

    var bytesPerSample: Int { fourcc == Wire.fourccP010 ? 2 : 1 }
    var lumaRowBytes: Int { width * bytesPerSample }
    var chromaRowBytes: Int { ((width + 1) & ~1) * bytesPerSample }
    var chromaRows: Int { (height + 1) / 2 }
    /// Size of the packed NV12/P010 layout used on the wire.
    var packedSize: Int { lumaRowBytes * height + chromaRowBytes * chromaRows }

    static func pixelFormat(_ fourcc: UInt32) -> OSType {
        fourcc == Wire.fourccP010 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    static func makeBuffer(width: Int, height: Int, fourcc: UInt32) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
        CVPixelBufferCreate(nil, width, height, pixelFormat(fourcc), attrs as CFDictionary, &pb)
        return pb
    }

    /// Copies a packed upload into a fresh pixel buffer (decoded buffers may be shared with VT,
    /// so they are never written in place).
    func put(_ packed: UnsafeRawBufferPointer) throws {
        guard packed.count >= packedSize else { throw WireError(.invalidParameter, "short surface upload") }
        guard let pb = Surface.makeBuffer(width: width, height: height, fourcc: fourcc) else {
            throw WireError(.allocationFailed, "CVPixelBufferCreate failed")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        var src = packed.baseAddress!
        for (plane, rows, rowBytes) in [(0, height, lumaRowBytes), (1, chromaRows, chromaRowBytes)] {
            let dst = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            if stride == rowBytes {
                memcpy(dst, src, rowBytes * rows)
            } else {
                for r in 0..<rows { memcpy(dst + r * stride, src + r * rowBytes, rowBytes) }
            }
            src += rowBytes * rows
        }
        buffer = pb
    }

    /// Row-by-row view of the surface in the packed wire layout, for `writev`. Rows the pixel
    /// buffer does not cover (it can be smaller than the surface) come from `zeros`.
    func withPackedRows<R>(_ body: ([iovec]) throws -> R) rethrows -> R {
        guard let pb = buffer else { return try body([]) }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var iov: [iovec] = []
        iov.reserveCapacity(height + chromaRows)
        let pbw = CVPixelBufferGetWidth(pb)
        let pbh = CVPixelBufferGetHeight(pb)
        let zeros = Surface.zeroRow(max(lumaRowBytes, chromaRowBytes))
        for (plane, rows, rowBytes, pbRows) in [(0, height, lumaRowBytes, pbh), (1, chromaRows, chromaRowBytes, (pbh + 1) / 2)] {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            let have = min(rowBytes, (plane == 0 ? pbw : (pbw + 1) & ~1) * bytesPerSample)
            for r in 0..<rows {
                if r < pbRows {
                    iov.append(iovec(iov_base: base + r * stride, iov_len: have))
                    if have < rowBytes { iov.append(iovec(iov_base: zeros, iov_len: rowBytes - have)) }
                } else {
                    iov.append(iovec(iov_base: zeros, iov_len: rowBytes))
                }
            }
        }
        return try body(iov)
    }

    private static let zeroLock = NSLock()
    nonisolated(unsafe) private static var zeroBuf: UnsafeMutableRawPointer?
    nonisolated(unsafe) private static var zeroLen = 0

    /// Shared read-only zero row used to pad short pictures.
    static func zeroRow(_ n: Int) -> UnsafeMutableRawPointer {
        zeroLock.lock()
        defer { zeroLock.unlock() }
        if n > zeroLen {
            zeroBuf = calloc(1, n)
            zeroLen = n
        }
        return zeroBuf!
    }
}

/// Copies the top-left `width`×`height` of a biplanar buffer into a new buffer of exactly that
/// size (decoded pictures are coded-size, e.g. 1088 rows for 1080p).
func cropBuffer(_ src: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
    let fmt = CVPixelBufferGetPixelFormatType(src)
    var out: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
    CVPixelBufferCreate(nil, width, height, fmt, attrs as CFDictionary, &out)
    guard let dst = out else { return nil }
    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
        CVPixelBufferUnlockBaseAddress(dst, [])
        CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }
    let bps = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 2 : 1
    let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
    for plane in 0..<2 {
        let rows = min(plane == 0 ? height : (height + 1) / 2, plane == 0 ? sh : (sh + 1) / 2)
        let rowBytes = min(width, sw) * bps
        let s = CVPixelBufferGetBaseAddressOfPlane(src, plane)!
        let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane)!
        let ss = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
        let ds = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
        for r in 0..<rows { memcpy(d + r * ds, s + r * ss, rowBytes) }
    }
    return dst
}
