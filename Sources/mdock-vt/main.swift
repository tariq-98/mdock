import Foundation
import VideoToolbox

// mdock-vt: VA-API → VideoToolbox host service (see accel/CONTRACT.md, accel/vaapi/PROTOCOL.md).

/// What this Mac's media engine can do, probed once.
enum Capabilities {
    static let current: Wire.Caps = {
        var caps: Wire.Caps = []
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) { caps.insert(.h264Decode) }
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { caps.formUnion([.hevcDecode, .hevc10Decode]) }
        if encoderAvailable(kCMVideoCodecType_H264) { caps.insert(.h264Encode) }
        if encoderAvailable(kCMVideoCodecType_HEVC) { caps.formUnion([.hevcEncode, .hevc10Encode]) }
        return caps
    }()

    private static func encoderAvailable(_ codec: CMVideoCodecType) -> Bool {
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var id: CFString?
        var props: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(
            width: 1920, height: 1080, codecType: codec, encoderSpecification: spec as CFDictionary,
            encoderIDOut: &id, supportedPropertiesOut: &props) == noErr
    }
}

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: mdock-vt serve --socket <path>
           mdock-vt serve --tcp <ip:port>    (testing only; never a wildcard address)
             [--frames-dir <dir>]            (default: <socket dir>/frames)
           mdock-vt caps

    """.data(using: .utf8)!)
    exit(2)
}

signal(SIGPIPE, SIG_IGN)
// The daemon spawns us with its signal mask (it handles SIGTERM itself); unblock so that
// stopping mdock actually stops this service.
var all = sigset_t()
sigfillset(&all)
sigprocmask(SIG_UNBLOCK, &all, nil)
signal(SIGTERM, SIG_DFL)
signal(SIGINT, SIG_DFL)
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

switch command {
case "serve":
    var socketPath: String?
    var tcp: String?
    var framesDir: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--socket" where i + 1 < args.count: socketPath = args[i + 1]; i += 2
        case "--tcp" where i + 1 < args.count: tcp = args[i + 1]; i += 2
        case "--frames-dir" where i + 1 < args.count: framesDir = args[i + 1]; i += 2
        default: usage()
        }
    }
    // Frame files default to <socket dir>/frames, which the CDI spec mounts into containers.
    if framesDir == nil, let socketPath {
        framesDir = ((socketPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("frames")
    }
    if let dir = framesDir {
        mkdir(dir, 0o711)
        chmod(dir, 0o711)
        // Leftovers from a previous run (connections that never closed cleanly).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("vt-") {
            unlink((dir as NSString).appendingPathComponent(name))
        }
    }
    do {
        let server: Server
        if let socketPath {
            server = try Server(unixPath: socketPath)
        } else if let tcp {
            server = try Server(tcp: tcp)
        } else {
            usage()
        }
        server.framesDir = framesDir
        log("mdock-vt: caps 0x\(String(Capabilities.current.rawValue, radix: 16)), frames dir \(framesDir ?? "none")")
        server.run()
    } catch {
        log("mdock-vt: \(error)")
        exit(1)
    }
case "caps":
    print("0x\(String(Capabilities.current.rawValue, radix: 16))")
default:
    usage()
}
