import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// One VA decode context: a VTDecompressionSession fed one access unit per call, in decode order.
/// Decoding is asynchronous so several frames are in flight; each output lands in the surface VA
/// asked for, and anything that reads that surface first waits (`Surface.decoding`).
final class Decoder {
    let codec: Wire.Codec
    let bitDepth: Int
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var paramBlob = Data()

    init(codec: Wire.Codec, bitDepth: Int) {
        self.codec = codec
        self.bitDepth = bitDepth
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Waits until every submitted frame has been delivered to its surface.
    func waitForFrames() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    /// Decodes one picture. `params` are SPS/PPS (and VPS) NAL units, `slices` the picture's slice
    /// NAL units, all without start codes.
    func decode(params: [UnsafeRawBufferPointer], slices: [UnsafeRawBufferPointer], into surface: Surface) throws {
        try updateFormat(params)
        guard let format, let session else { throw WireError(.decodingError, "no decoder session") }

        var total = 0
        for s in slices { total += 4 + s.count }
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: total, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard st == noErr, let block else { throw WireError(.allocationFailed, "CMBlockBuffer \(st)") }
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &ptr)
        var p = UnsafeMutableRawPointer(ptr!)
        for s in slices {
            p.storeBytes(of: UInt32(s.count).bigEndian, as: UInt32.self)
            memcpy(p + 4, s.baseAddress!, s.count)
            p += 4 + s.count
        }

        var sample: CMSampleBuffer?
        var size = total
        st = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        guard st == noErr, let sample else { throw WireError(.allocationFailed, "CMSampleBuffer \(st)") }

        let codec = self.codec
        surface.decoding = self
        st = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) {
            status, _, image, _, _ in
            if status == noErr, let image {
                surface.buffer = image
            } else {
                log("decoder: \(codec) frame failed (\(status))")
            }
        }
        if st != noErr {
            surface.decoding = nil
            // A failed session (e.g. after a bad frame) is rebuilt on the next picture.
            if st == kVTInvalidSessionErr {
                self.session = nil
                self.paramBlob = Data()
            }
            throw WireError(.decodingError, "VTDecompressionSessionDecodeFrame \(st)")
        }
    }

    /// Rebuilds the format description when the parameter sets change, and the session when the
    /// new description is incompatible with it.
    private func updateFormat(_ params: [UnsafeRawBufferPointer]) throws {
        var blob = Data()
        for p in params {
            withUnsafeBytes(of: UInt32(p.count)) { blob.append(contentsOf: $0) }
            blob.append(contentsOf: p)
        }
        if blob == paramBlob, session != nil { return }

        var fmt: CMVideoFormatDescription?
        let pointers = params.map { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
        let sizes = params.map(\.count)
        let st: OSStatus = pointers.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { sp in
                switch codec {
                case .h264:
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil, parameterSetCount: params.count, parameterSetPointers: pp.baseAddress!,
                        parameterSetSizes: sp.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
                case .hevc:
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: params.count, parameterSetPointers: pp.baseAddress!,
                        parameterSetSizes: sp.baseAddress!, nalUnitHeaderLength: 4, extensions: nil,
                        formatDescriptionOut: &fmt)
                }
            }
        }
        guard st == noErr, let fmt else { throw WireError(.decodingError, "parameter sets rejected (\(st))") }
        paramBlob = blob
        format = fmt

        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: fmt) { return }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil

        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Surface.pixelFormat(bitDepth > 8 ? Wire.fourccP010 : Wire.fourccNV12),
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var s: VTDecompressionSession?
        let cs = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: fmt, decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard cs == noErr, let s else { throw WireError(.decodingError, "VTDecompressionSessionCreate \(cs)") }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        log("decoder: \(codec) \(dims.width)x\(dims.height) \(bitDepth)-bit session created")
    }
}
