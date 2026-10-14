import AVFoundation
import CoreMedia
import Foundation
import Speech

/// OpenAI-compatible `/v1/audio/transcriptions` using on-device `SpeechAnalyzer` + `SpeechTranscriber`.
/// No TCC prompt is involved: unlike `SFSpeechRecognizer`, the macOS 26 analyzer works from a CLI.
enum Transcription {
    static func status() -> [String: Any] {
        guard #available(macOS 26.0, *) else { return ["available": false, "reason": "requires macOS 26"] }
        let installed = (try? blocking { await SpeechTranscriber.installedLocales.map(\.identifier).sorted() }) ?? []
        return ["available": SpeechTranscriber.isAvailable, "engine": "SpeechAnalyzer/SpeechTranscriber",
                "installed_locales": installed,
                "note": "other supported locales are downloaded on first use"]
    }

    static func handle(_ req: HTTPRequest, _ r: HTTPResponder) throws {
        guard #available(macOS 26.0, *) else { throw HTTPError(503, "speech transcription requires macOS 26") }
        guard SpeechTranscriber.isAvailable else {
            throw HTTPError(503, "SpeechTranscriber is not available on this Mac", type: "unavailable")
        }
        guard req.contentType.lowercased().hasPrefix("multipart/form-data") else {
            throw HTTPError(400, "expected multipart/form-data with a 'file' field")
        }
        let form = try Multipart.parse(try req.body(), contentType: req.contentType)
        guard let file = form.first(where: { $0.name == "file" }), !file.data.isEmpty else {
            throw HTTPError(400, "missing 'file'")
        }
        let format = Multipart.field(form, "response_format") ?? "json"
        guard ["json", "text", "verbose_json", "srt", "vtt"].contains(format) else {
            throw HTTPError(400, "response_format must be json, text, verbose_json, srt or vtt")
        }
        let words = form.contains { $0.name.hasPrefix("timestamp_granularities") && String(decoding: $0.data, as: UTF8.self).contains("word") }
        let language = Multipart.field(form, "language").flatMap { $0.isEmpty ? nil : $0 } ?? "en-US"
        let prompt = Multipart.field(form, "prompt")

        let ext = ((file.filename ?? "audio.wav") as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdock-ml-audio-\(UUID().uuidString).\(ext.isEmpty ? "wav" : ext)")
        try file.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let start = DispatchTime.now()
        let result = try blocking {
            try await transcribe(url, language: language, timed: format != "json" && format != "text" || words, prompt: prompt)
        }
        let elapsed = milliseconds(since: start)
        Log.info("transcription: \(String(format: "%.1f", result.duration))s audio in \(Int(elapsed))ms [\(result.locale)]")

        switch format {
        case "text": r.text(200, result.text + "\n")
        case "srt": r.text(200, subtitles(result.segments, vtt: false), contentType: "application/x-subrip; charset=utf-8")
        case "vtt": r.text(200, subtitles(result.segments, vtt: true), contentType: "text/vtt; charset=utf-8")
        case "verbose_json":
            var body: [String: Any] = [
                "task": "transcribe",
                "language": Locale(identifier: "en").localizedString(forLanguageCode: result.locale.split(separator: "_").first.map(String.init) ?? "en")?.lowercased() ?? result.locale,
                "duration": rounded(result.duration, 3),
                "text": result.text,
                "segments": result.segments.enumerated().map { i, s in
                    ["id": i, "seek": 0, "start": rounded(s.start, 3), "end": rounded(s.end, 3), "text": s.text,
                     "tokens": [Int](), "temperature": 0.0, "avg_logprob": 0.0, "compression_ratio": 0.0, "no_speech_prob": 0.0] as [String: Any]
                },
                "processing_ms": rounded(elapsed),
            ]
            if words { body["words"] = result.words.map { ["word": $0.text, "start": rounded($0.start, 3), "end": rounded($0.end, 3)] } }
            r.json(200, body)
        default:
            var body: [String: Any] = ["text": result.text]
            if words { body["words"] = result.words.map { ["word": $0.text, "start": rounded($0.start, 3), "end": rounded($0.end, 3)] } }
            r.json(200, body)
        }
    }

    struct Timed { var text: String; var start: Double; var end: Double }
    struct Result { var text: String; var segments: [Timed]; var words: [Timed]; var duration: Double; var locale: String }

    @available(macOS 26.0, *)
    static func transcribe(_ url: URL, language: String, timed: Bool, prompt: String?) async throws -> Result {
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: url) } catch {
            throw HTTPError(400, "unsupported or corrupt audio (\(error.localizedDescription)); use wav, mp3, m4a/aac, flac, aiff or caf",
                            code: "unsupported_audio")
        }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
            throw HTTPError(400, "language '\(language)' is not supported; supported: \(supported.joined(separator: ", "))",
                            code: "unsupported_language")
        }
        let transcriber = timed
            ? SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            : SpeechTranscriber(locale: locale, preset: .transcription)
        if await AssetInventory.status(forModules: [transcriber]) < .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.info("speech: downloading model assets for \(locale.identifier)")
                try await request.downloadAndInstall()
            }
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let prompt, !prompt.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = prompt.split(whereSeparator: { $0.isWhitespace || $0 == "," })
                .map(String.init).filter { $0.count > 2 }
            try? await analyzer.setContext(context)
        }
        let collector = Task { () -> ([Timed], [Timed]) in
            var segments: [Timed] = []
            var words: [Timed] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                segments.append(Timed(text: text, start: result.range.start.seconds,
                                      end: (result.range.start + result.range.duration).seconds))
                if timed {
                    for run in result.text.runs {
                        guard let range = run.audioTimeRange else { continue }
                        let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                        if word.isEmpty { continue }
                        words.append(Timed(text: word, start: range.start.seconds, end: (range.start + range.duration).seconds))
                    }
                }
            }
            return (segments, words)
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw HTTPError(500, "transcription failed: \(error.localizedDescription)")
        }
        let (segments, words) = try await collector.value
        let text = segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return Result(text: text, segments: segments.map {
            Timed(text: $0.text.trimmingCharacters(in: .whitespaces), start: $0.start, end: $0.end)
        }, words: words, duration: duration, locale: locale.identifier)
    }

    private static func subtitles(_ segments: [Timed], vtt: Bool) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, vtt ? "." : ",", ms % 1000)
        }
        var out = vtt ? "WEBVTT\n\n" : ""
        for (i, s) in segments.enumerated() where !s.text.isEmpty {
            if !vtt { out += "\(i + 1)\n" }
            out += "\(stamp(s.start)) --> \(stamp(s.end))\n\(s.text)\n\n"
        }
        return out
    }
}
