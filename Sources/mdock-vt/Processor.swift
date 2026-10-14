import CoreVideo
import Foundation
import VideoToolbox

/// VA video processing (VAEntrypointVideoProc): crop, scale and NV12/P010 conversion between
/// surfaces, done by a VTPixelTransferSession.
final class Processor {
    private var session: VTPixelTransferSession?

    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    struct Rect {
        var x, y, width, height: Int
    }

    /// Renders `src` cropped to `srcRect` into `dstRect` of a new `dst`-sized picture.
    func process(_ src: CVPixelBuffer, srcRect: Rect, into dst: Surface, dstRect: Rect) throws -> CVPixelBuffer {
        if session == nil {
            var s: VTPixelTransferSession?
            let st = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s)
            guard st == noErr, let s else { throw WireError(.operationFailed, "VTPixelTransferSessionCreate \(st)") }
            VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
            session = s
        }
        guard let session, let out = Surface.makeBuffer(width: dst.width, height: dst.height, fourcc: dst.fourcc) else {
            throw WireError(.allocationFailed, "output buffer")
        }
        let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
        let fullSource = srcRect.x == 0 && srcRect.y == 0 && srcRect.width == sw && srcRect.height == sh
        let fullTarget = dstRect.x == 0 && dstRect.y == 0 && dstRect.width == dst.width && dstRect.height == dst.height

        if !fullSource {
            let aperture: [CFString: Any] = [
                kCVImageBufferCleanApertureWidthKey: srcRect.width,
                kCVImageBufferCleanApertureHeightKey: srcRect.height,
                kCVImageBufferCleanApertureHorizontalOffsetKey: Double(srcRect.x) + Double(srcRect.width - sw) / 2,
                kCVImageBufferCleanApertureVerticalOffsetKey: Double(srcRect.y) + Double(srcRect.height - sh) / 2,
            ]
            CVBufferSetAttachment(src, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)
        }
        defer { if !fullSource { CVBufferRemoveAttachment(src, kCVImageBufferCleanApertureKey) } }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                             value: fullSource ? kVTScalingMode_Normal : kVTScalingMode_CropSourceToCleanAperture)

        if fullTarget {
            let st = VTPixelTransferSessionTransferImage(session, from: src, to: out)
            guard st == noErr else { throw WireError(.operationFailed, "VTPixelTransferSessionTransferImage \(st)") }
            return out
        }
        // Letterboxed output: scale into a temporary picture, then place it on black.
        guard let tmp = Surface.makeBuffer(width: dstRect.width, height: dstRect.height, fourcc: dst.fourcc) else {
            throw WireError(.allocationFailed, "temporary buffer")
        }
        let st = VTPixelTransferSessionTransferImage(session, from: src, to: tmp)
        guard st == noErr else { throw WireError(.operationFailed, "VTPixelTransferSessionTransferImage \(st)") }
        fillBlack(out, tenBit: dst.fourcc == Wire.fourccP010)
        blit(tmp, into: out, x: dstRect.x, y: dstRect.y, bytesPerSample: dst.bytesPerSample)
        return out
    }

    private func fillBlack(_ pb: CVPixelBuffer, tenBit: Bool) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane)
            if tenBit {
                let v: UInt16 = plane == 0 ? 64 << 6 : 512 << 6
                let p = base.bindMemory(to: UInt16.self, capacity: bytes / 2)
                for i in 0..<(bytes / 2) { p[i] = v }
            } else {
                memset(base, plane == 0 ? 16 : 128, bytes)
            }
        }
    }

    private func blit(_ src: CVPixelBuffer, into dst: CVPixelBuffer, x: Int, y: Int, bytesPerSample: Int) {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        for plane in 0..<2 {
            let div = plane == 0 ? 1 : 2
            let rows = min(CVPixelBufferGetHeightOfPlane(src, plane), CVPixelBufferGetHeightOfPlane(dst, plane) - y / div)
            let rowBytes = min(CVPixelBufferGetWidth(src), CVPixelBufferGetWidth(dst) - x) * bytesPerSample
            guard rows > 0, rowBytes > 0 else { continue }
            let s = CVPixelBufferGetBaseAddressOfPlane(src, plane)!
            let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane)!
            let ss = CVPixelBufferGetBytesPerRowOfPlane(src, plane), ds = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            let xOff = (x / 2 * 2) * bytesPerSample
            for r in 0..<rows { memcpy(d + (y / div + r) * ds + xOff, s + r * ss, rowBytes) }
        }
    }
}
