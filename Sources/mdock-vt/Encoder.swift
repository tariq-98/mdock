import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Encoder settings taken from the VA sequence, picture and misc parameter buffers.
struct EncoderConfig: Equatable {
    enum RateControl: UInt32 { case cqp = 1, cbr = 2, vbr = 3 }

    var codec: Wire.Codec
    var width: Int
    var height: Int
    var bitDepth: Int
    var profile: UInt32  // 0 baseline, 1 main, 2 high (H.264); main/main10 follow bitDepth for HEVC
    var rateControl: RateControl
    var bitrate: Int  // bits/s
    var maxBitrate: Int
    var fpsNum: Int
    var fpsDen: Int
    var gop: Int  // frames between IDRs, 0 = encoder default
    var qp: Int
    var bufferBits: Int

    init(_ r: inout Reader) throws {
        guard let c = Wire.Codec(rawValue: try r.u32()) else { throw WireError(.unsupportedProfile, "codec") }
        codec = c
        width = Int(try r.u32())
        height = Int(try r.u32())
        bitDepth = Int(try r.u32())
        profile = try r.u32()
        rateControl = RateControl(rawValue: try r.u32()) ?? .vbr
        bitrate = Int(try r.u32())
        maxBitrate = Int(try r.u32())
        fpsNum = Int(try r.u32())
        fpsDen = Int(try r.u32())
        gop = Int(try r.u32())
        qp = Int(try r.u32())
        bufferBits = Int(try r.u32())
        if fpsNum == 0 || fpsDen == 0 { fpsNum = 30; fpsDen = 1 }
    }
}

/// One VA encode context backed by a hardware VTCompressionSession. Frame reordering is off
/// (the driver advertises no B-frames), so each submitted surface yields exactly one access unit.
final class Encoder {
    private(set) var config: EncoderConfig
    private var session: VTCompressionSession?
    private var frameIndex: Int64 = 0
    private var lastPTS = CMTime.invalid

    init(_ config: EncoderConfig) throws {
        self.config = config
        try createSession()
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    private func createSession() throws {
        let codecType = config.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(config.width), height: Int32(config.height), codecType: codecType,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw WireError(.encodingError, "VTCompressionSessionCreate \(st)") }
        session = s

        let profile: CFString
        switch config.codec {
        case .h264:
            profile = [kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel, kVTProfileLevel_H264_Main_AutoLevel,
                       kVTProfileLevel_H264_High_AutoLevel][Int(min(config.profile, 2))]
        case .hevc:
            profile = config.bitDepth > 8 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        }
        set(kVTCompressionPropertyKey_ProfileLevel, profile)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        if config.codec == .h264 { set(kVTCompressionPropertyKey_H264EntropyMode, config.profile == 0 ? kVTH264EntropyMode_CAVLC : kVTH264EntropyMode_CABAC) }
        applyRateControl()
        VTCompressionSessionPrepareToEncodeFrames(s)
        log("encoder: \(config.codec) \(config.width)x\(config.height) \(config.bitDepth)-bit rc=\(config.rateControl) "
            + "bitrate=\(config.bitrate) max=\(config.maxBitrate) qp=\(config.qp) gop=\(config.gop) fps=\(config.fpsNum)/\(config.fpsDen)")
    }

    private func set(_ key: CFString, _ value: CFTypeRef) {
        guard let session else { return }
        let st = VTSessionSetProperty(session, key: key, value: value)
        if st != noErr { log("encoder: \(key) rejected (\(st))") }
    }

    private func applyRateControl() {
        let fps = Double(config.fpsNum) / Double(config.fpsDen)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        // IDRs are forced per frame by the driver; this only bounds the encoder's own choice.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (config.gop > 0 ? config.gop : 100_000) as CFNumber)
        switch config.rateControl {
        case .cqp:
            let qp = max(1, min(config.qp > 0 ? config.qp : 26, 51))
            set(kVTCompressionPropertyKey_MinAllowedFrameQP, qp as CFNumber)
            set(kVTCompressionPropertyKey_MaxAllowedFrameQP, qp as CFNumber)
        case .cbr:
            if config.bitrate > 0 {
                set(kVTCompressionPropertyKey_ConstantBitRate, config.bitrate as CFNumber)
            }
        case .vbr:
            if config.bitrate > 0 {
                set(kVTCompressionPropertyKey_AverageBitRate, config.bitrate as CFNumber)
                let peak = max(config.maxBitrate, config.bitrate)
                // DataRateLimits is bytes per window; one second at the peak rate.
                set(kVTCompressionPropertyKey_DataRateLimits, [peak / 8, 1] as CFArray)
            }
        }
    }

    /// Applies a changed configuration: rate control in place, anything else via a new session.
    func reconfigure(_ new: EncoderConfig) throws {
        guard new != config else { return }
        let sameShape = new.codec == config.codec && new.width == config.width && new.height == config.height
            && new.bitDepth == config.bitDepth && new.profile == config.profile && new.rateControl == config.rateControl
        config = new
        if sameShape {
            applyRateControl()
        } else {
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
            try createSession()
        }
    }

    /// Submits one picture; `done` runs on a VideoToolbox thread with the access unit as Annex B
    /// (parameter sets in front of keyframes). Frames complete in submission order.
    func encode(_ source: CVPixelBuffer, forceKey: Bool, done: @escaping (Data, Bool, OSStatus) -> Void) throws {
        guard let session else { throw WireError(.encodingError, "no encoder session") }
        var image = source
        if CVPixelBufferGetWidth(source) != config.width || CVPixelBufferGetHeight(source) != config.height {
            guard let cropped = cropBuffer(source, width: config.width, height: config.height) else {
                throw WireError(.allocationFailed, "crop failed")
            }
            image = cropped
        }
        let pts = CMTime(value: frameIndex * Int64(config.fpsDen), timescale: Int32(config.fpsNum))
        let duration = CMTime(value: Int64(config.fpsDen), timescale: Int32(config.fpsNum))
        frameIndex += 1
        lastPTS = pts
        let props: [CFString: Any]? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : nil
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: pts, duration: duration,
            frameProperties: props as CFDictionary?, infoFlagsOut: nil) { status, flags, sample in
            if status == noErr, let sample {
                let (data, key) = Encoder.annexB(sample)
                done(data, key, noErr)
            } else {
                done(Data(), false, status != noErr ? status : (flags.contains(.frameDropped) ? kVTVideoEncoderMalfunctionErr : noErr))
            }
        }
        guard st == noErr else { throw WireError(.encodingError, "VTCompressionSessionEncodeFrame \(st)") }
    }

    /// Forces out every submitted frame (the driver asks when it is waiting for one).
    func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: lastPTS)
    }

    /// Converts a length-prefixed sample to Annex B, prepending VPS/SPS/PPS on keyframes.
    static func annexB(_ sample: CMSampleBuffer) -> (Data, Bool) {
        var key = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, first[kCMSampleAttachmentKey_NotSync] as? Bool == true {
            key = false
        }
        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        if key, let fmt = CMSampleBufferGetFormatDescription(sample) {
            let hevc = CMFormatDescriptionGetMediaSubType(fmt) == kCMVideoCodecType_HEVC
            var count = 0
            if hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if hevc {
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }
                if let ptr {
                    out.append(contentsOf: startCode)
                    out.append(ptr, count: size)
                }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return (out, key) }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
        var i = 0
        while i + 4 <= length {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard n > 0, i + n <= length else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[i..<(i + n)])
            i += n
        }
        return (out, key)
    }
}
