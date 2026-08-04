import Foundation
import AVFoundation
import CoreMedia

/// Audio and video.
///
/// Audio goes through `afconvert`, which ships with macOS and can write every format Core Audio
/// knows. Three cannot go that way — MP3 has no encoder there, and Opus and Ogg Vorbis need a
/// container `afconvert` cannot write at all — so those route through ffmpeg, as does every video.
enum MediaPass {

    struct Outcome {
        let outputURL: URL
        let size: Int64
    }

    enum Failure: LocalizedError {
        case noFFmpeg(String)
        case unreadable(URL)
        case toolFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFFmpeg(let what):
                return "\(what) needs ffmpeg, which is not in this build."
            case .unreadable(let url):
                return "\(url.lastPathComponent) could not be read."
            case .toolFailed(let message):
                return message
            }
        }
    }

    // MARK: - Audio

    static func runAudio(_ url: URL,
                         stage: ShrinkStage,
                         into destination: URL) throws -> Outcome {
        guard case .audio(let requested) = stage.target else { throw Failure.unreadable(url) }
        // `keep` re-encodes in place: same container, lower bitrate.
        let format = requested == .keep ? (existingAudioFormat(url) ?? .aac) : requested

        if format.needsFFmpeg {
            guard let ffmpeg = Shell.ffmpeg else { throw Failure.noFFmpeg(format.title) }
            return try runFFmpeg(ffmpeg,
                                 arguments: audioFFmpegArguments(for: format, quality: stage.quality),
                                 source: url,
                                 extension: format.fileExtension ?? "m4a",
                                 into: destination)
        }
        return try runAFConvert(url, format: format, quality: stage.quality, into: destination)
    }

    private static func runAFConvert(_ url: URL,
                                     format: AudioFormat,
                                     quality: Double,
                                     into destination: URL) throws -> Outcome {
        let ext = format.fileExtension ?? "m4a"
        let output = try ArchivePass.unusedURL(
            named: "\(url.deletingPathExtension().lastPathComponent).\(ext)", in: destination)

        var arguments = ["-f", afconvertContainer(format), "-d", afconvertCodec(format)]
        if format.isLossy {
            // Bitrate rather than a quality index: `afconvert`'s VBR quality scale is per-codec
            // and largely undocumented, while a bitrate means the same thing everywhere.
            arguments += ["-b", String(audioBitrate(for: quality)), "-q", "127", "-s", "3"]
        }
        arguments += [url.path, output.path]

        let result = try Shell.run(Shell.afconvert, arguments)
        guard result.ok else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.toolFailed(result.message)
        }
        return Outcome(outputURL: output, size: size(of: output))
    }

    /// 64–256 kbps across the quality slider. Below 64 speech starts to smear; above 256 an AAC
    /// encoder is spending bytes nobody can hear.
    static func audioBitrate(for quality: Double) -> Int {
        let clamped = quality.clamped(0, 1)
        let kbps = 64 + (clamped * 192)
        // Round to a multiple of 8 — encoders do this anyway, and a round number reads better.
        return Int((kbps / 8).rounded()) * 8 * 1000
    }

    private static func afconvertContainer(_ format: AudioFormat) -> String {
        switch format {
        case .aac, .alac: return "m4af"
        case .flac:       return "flac"
        case .wav:        return "WAVE"
        case .aiff:       return "AIFF"
        default:          return "m4af"
        }
    }

    private static func afconvertCodec(_ format: AudioFormat) -> String {
        switch format {
        case .aac:  return "aac "     // the trailing space is part of the four-character code
        case .alac: return "alac"
        case .flac: return "flac"
        case .wav, .aiff: return "LEI16"
        default:    return "aac "
        }
    }

    private static func audioFFmpegArguments(for format: AudioFormat, quality: Double) -> [String] {
        let bitrate = "\(audioBitrate(for: quality) / 1000)k"
        switch format {
        case .mp3:    return ["-c:a", "libmp3lame", "-b:a", bitrate]
        case .opus:   return ["-c:a", "libopus", "-b:a", bitrate]
        case .vorbis: return ["-c:a", "libvorbis", "-b:a", bitrate]
        default:      return ["-c:a", "aac", "-b:a", bitrate]
        }
    }

    private static func existingAudioFormat(_ url: URL) -> AudioFormat? {
        switch url.pathExtension.lowercased() {
        case "m4a", "aac": return .aac
        case "mp3":  return .mp3
        case "flac": return .flac
        case "wav":  return .wav
        case "aiff", "aif": return .aiff
        case "opus": return .opus
        case "ogg":  return .vorbis
        default:     return nil
        }
    }

    // MARK: - Video

    static func runVideo(_ url: URL,
                         stage: ShrinkStage,
                         scrub: ScrubLevel,
                         into destination: URL,
                         onProgress: (@Sendable (Double) -> Void)? = nil) throws -> Outcome {
        guard case .video(let requested) = stage.target else { throw Failure.unreadable(url) }
        guard let ffmpeg = Shell.ffmpeg else { throw Failure.noFFmpeg("Video") }
        let format = requested == .keep ? .h264 : requested

        var arguments = videoFFmpegArguments(for: format, quality: stage.quality)
        // ffmpeg copies input metadata by default, GPS and all. `-map_metadata -1` is the whole
        // scrub for video: there is no per-field surgery to do, so anything short of
        // keep-everything drops the lot.
        if scrub != .keepEverything { arguments += ["-map_metadata", "-1"] }

        return try runFFmpeg(ffmpeg,
                             arguments: arguments,
                             source: url,
                             extension: format.fileExtension ?? "mp4",
                             into: destination,
                             onProgress: onProgress)
    }

    /// How long the file runs, in seconds. Needed to turn ffmpeg's elapsed-output-time into a
    /// fraction — without it there is a number but nothing to divide by.
    static func duration(of url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        let box = DurationBox()
        Task.detached {
            if let time = try? await asset.load(.duration) {
                box.seconds = CMTimeGetSeconds(time)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.seconds.isFinite && box.seconds > 0 ? box.seconds : 0
    }

    private final class DurationBox: @unchecked Sendable { var seconds: Double = 0 }

    private static func videoFFmpegArguments(for format: VideoFormat, quality: Double) -> [String] {
        // CRF, inverted: lower is better quality. 18 is visually lossless, 32 is soft. Map the
        // slider onto 32…18 so "higher quality" moves the right way.
        let crf = Int((32 - (quality.clamped(0, 1) * 14)).rounded())
        switch format {
        case .hevc:
            return ["-c:v", "libx265", "-crf", String(crf), "-preset", "medium",
                    "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "128k"]
        case .webm:
            return ["-c:v", "libvpx-vp9", "-crf", String(crf), "-b:v", "0",
                    "-c:a", "libopus", "-b:a", "128k"]
        case .h264, .keep:
            return ["-c:v", "libx264", "-crf", String(crf), "-preset", "medium",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k"]
        }
    }

    // MARK: - Shared

    private static func runFFmpeg(_ ffmpeg: URL,
                                  arguments: [String],
                                  source: URL,
                                  extension ext: String,
                                  into destination: URL,
                                  onProgress: (@Sendable (Double) -> Void)? = nil) throws -> Outcome {
        let output = try ArchivePass.unusedURL(
            named: "\(source.deletingPathExtension().lastPathComponent).\(ext)", in: destination)

        // `-nostdin` matters: without it ffmpeg competes for the terminal and can hang a run.
        var full = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path]
            + arguments

        // `-progress pipe:1` writes a block of `key=value` lines to stdout every second or so.
        // It is the only way to know how far along a transcode is; the alternative is a bar that
        // sits at 0% for four minutes and then jumps to done.
        let total = onProgress == nil ? 0 : duration(of: source)
        if onProgress != nil { full += ["-progress", "pipe:1", "-nostats"] }
        full.append(output.path)

        let result: ShellResult
        if let onProgress, total > 0 {
            result = try Shell.stream(ffmpeg, full) { line in
                // `out_time_us=12345678` — microseconds of output written so far.
                guard let value = line.split(separator: "=", maxSplits: 1).last,
                      line.hasPrefix("out_time_us="),
                      let microseconds = Double(value.trimmingCharacters(in: .whitespaces))
                else { return }
                let fraction = (microseconds / 1_000_000) / total
                onProgress(min(max(fraction, 0), 1))
            }
        } else {
            result = try Shell.run(ffmpeg, full)
        }
        guard result.ok else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.toolFailed(result.message)
        }
        return Outcome(outputURL: output, size: size(of: output))
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
    }

    /// True when the file really contains a playable audio track.
    static func hasAudioTrack(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        let box = TrackBox()
        Task.detached {
            box.count = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
            semaphore.signal()
        }
        semaphore.wait()
        return box.count > 0
    }

    private final class TrackBox: @unchecked Sendable {
        var count = 0
    }

    // MARK: - Self-check

    static func selfCheck() {
        // The bitrate curve moves the right way and stays inside the useful band.
        assert(audioBitrate(for: 0.0) == 64_000)
        assert(audioBitrate(for: 1.0) == 256_000)
        assert(audioBitrate(for: 0.75) > audioBitrate(for: 0.25), "quality must raise the bitrate")
        assert(audioBitrate(for: -5) == 64_000 && audioBitrate(for: 9) == 256_000,
               "a slider outside 0…1 must clamp, not produce a nonsense bitrate")
        assert(audioBitrate(for: 0.5) % 8000 == 0, "bitrates land on a round number of kbps")

        // CRF is inverted: a higher quality slider must produce a *lower* CRF.
        let low = videoFFmpegArguments(for: .h264, quality: 0.2)
        let high = videoFFmpegArguments(for: .h264, quality: 0.9)
        let crfLow = Int(low[low.firstIndex(of: "-crf")! + 1])!
        let crfHigh = Int(high[high.firstIndex(of: "-crf")! + 1])!
        assert(crfHigh < crfLow, "CRF is inverted — higher quality must mean a lower number")
        assert((18...32).contains(crfLow) && (18...32).contains(crfHigh))

        // HEVC must carry the hvc1 tag or QuickTime refuses to play the result.
        assert(videoFFmpegArguments(for: .hevc, quality: 0.7).contains("hvc1"),
               "HEVC without the hvc1 tag will not play in QuickTime")
        // H.264 must be yuv420p or the file plays everywhere except the places people use.
        assert(videoFFmpegArguments(for: .h264, quality: 0.7).contains("yuv420p"))

        // The three formats afconvert cannot write route to ffmpeg, and the rest do not.
        assert(AudioFormat.mp3.needsFFmpeg && AudioFormat.opus.needsFFmpeg && AudioFormat.vorbis.needsFFmpeg)
        assert(!AudioFormat.aac.needsFFmpeg && !AudioFormat.flac.needsFFmpeg)

        // Without ffmpeg, an MP3 request fails with a reason naming the tool — never silently
        // writing an AAC file with an .mp3 extension.
        if !Shell.hasFFmpeg {
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "trinket-media-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: folder) }
            let fake = folder.appending(path: "song.wav")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data(repeating: 0, count: 64).write(to: fake)
            do {
                _ = try runAudio(fake, stage: ShrinkStage(kind: .audio, target: .audio(.mp3)), into: folder)
                assertionFailure("MP3 without ffmpeg must throw, not write a mislabelled file")
            } catch {
                assert(error is Failure)
            }
        }

        // Real audio, when afconvert is there: a WAV in must produce a smaller AAC out.
        audioRoundTripCheck()
    }

    private static func audioRoundTripCheck() {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "trinket-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        guard let wav = writeProbeWAV(into: folder) else { return }
        let stage = ShrinkStage(kind: .audio, target: .audio(.aac), quality: 0.5)
        guard let outcome = try? runAudio(wav, stage: stage, into: folder) else {
            assertionFailure("afconvert failed on a plain 16-bit WAV")
            return
        }
        assert(outcome.size > 0, "the encoder wrote an empty file")
        assert(outcome.size < size(of: wav), "AAC at 128 kbps must be smaller than raw PCM")
        assert(outcome.outputURL.pathExtension == "m4a")
        // And the result is actually readable as audio, not just bytes on disk. `afconvert`
        // reporting success is not the same as the file having a playable track in it.
        assert(hasAudioTrack(outcome.outputURL), "the result has no audio track")
    }

    /// One second of a 440 Hz tone, 16-bit mono at 44.1 kHz. Written by hand so the check needs
    /// no sample file on disk.
    private static func writeProbeWAV(into folder: URL) -> URL? {
        let rate = 44_100, seconds = 1
        let frames = rate * seconds
        var samples = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let value = sin(Double(frame) * 2 * .pi * 440 / Double(rate))
            let sample = Int16(value * 24_000)
            withUnsafeBytes(of: sample.littleEndian) { samples.append(contentsOf: $0) }
        }

        var file = Data()
        func append(_ text: String) { file.append(contentsOf: text.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }

        append("RIFF"); append32(UInt32(36 + samples.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(rate)); append32(UInt32(rate * 2)); append16(2); append16(16)
        append("data"); append32(UInt32(samples.count)); file.append(samples)

        let url = folder.appending(path: "probe.wav")
        guard (try? file.write(to: url)) != nil else { return nil }
        return url
    }
}
