import Foundation

/// Result of running a command-line tool.
struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { status == 0 }
    /// Tools disagree about which stream carries the reason; take whichever spoke.
    var message: String {
        let text = stderr.isEmpty ? stdout : stderr
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ShellError: LocalizedError {
    case toolMissing(String)
    case failed(tool: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let name):
            return "\(name) is not available in this build."
        case .failed(let tool, let status, let message):
            return message.isEmpty ? "\(tool) exited with code \(status)" : message
        }
    }
}

/// Runs the command-line tools trinket leans on: `afconvert` and `ditto` from the system, and the
/// vendored `ffmpeg`. Nothing here ever touches a shell — arguments are passed as an array, so a
/// filename with a space or a quote in it cannot become two arguments or an injection.
enum Shell {
    /// Both pipes are drained on background queues before waiting. Reading them in sequence after
    /// the process exits deadlocks the moment either fills its 64 KB buffer, which ffmpeg's
    /// progress chatter does within a second.
    static func run(_ executable: URL, _ arguments: [String]) throws -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ShellError.toolMissing(executable.lastPathComponent)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        var outData = Data(), errData = Data()
        let lock = NSLock()
        let group = DispatchGroup()

        for (pipe, sink) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if sink { outData = data } else { errData = data }
                lock.unlock()
                group.leave()
            }
        }

        try process.run()
        process.waitUntilExit()
        group.wait()

        return ShellResult(status: process.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Same as `run`, but hands each line of **stdout** to `onLine` as it arrives.
    ///
    /// This is what makes a long encode show movement. `run` waits for the process to exit, so a
    /// four-minute transcode reports nothing until it is over — which reads as a hang, and is the
    /// single worst thing a progress bar can do.
    ///
    /// `onLine` is called on a background queue and may be called very often (ffmpeg emits a block
    /// roughly twice a second), so it must be cheap and must not touch the UI directly.
    static func stream(_ executable: URL,
                       _ arguments: [String],
                       onLine: @escaping @Sendable (String) -> Void) throws -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ShellError.toolMissing(executable.lastPathComponent)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        var errData = Data()
        let lock = NSLock()
        let group = DispatchGroup()

        // stdout, read incrementally and split into lines. A partial line is carried over rather
        // than delivered — half a `key=value` parses as nonsense.
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var carry = Data()
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                carry.append(chunk)
                while let newline = carry.firstIndex(of: 0x0A) {
                    let line = carry[carry.startIndex..<newline]
                    carry = carry[carry.index(after: newline)...]
                    onLine(String(decoding: line, as: UTF8.self))
                }
            }
            if !carry.isEmpty { onLine(String(decoding: carry, as: UTF8.self)) }
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = data; lock.unlock()
            group.leave()
        }

        try process.run()
        process.waitUntilExit()
        group.wait()

        return ShellResult(status: process.terminationStatus,
                           stdout: "",
                           stderr: String(decoding: errData, as: UTF8.self))
    }

    @discardableResult
    static func require(_ executable: URL, _ arguments: [String]) throws -> ShellResult {
        let result = try run(executable, arguments)
        guard result.ok else {
            throw ShellError.failed(tool: executable.lastPathComponent,
                                    status: result.status,
                                    message: result.message)
        }
        return result
    }

    // MARK: - Known tools

    /// `package-app.sh` puts the vendored build at `Contents/Resources/bin/ffmpeg`. nil when the
    /// tarball was absent at package time — the UI must then say video is unavailable rather than
    /// offer it and fail at run time.
    static let ffmpeg: URL? = {
        guard let url = Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "bin"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }()

    /// Ships with macOS; used for every audio format Core Audio can write.
    static let afconvert = URL(filePath: "/usr/bin/afconvert")

    static var hasFFmpeg: Bool { ffmpeg != nil }

    static func selfCheck() {
        // `afconvert` is part of the OS. If this is ever false the audio engine's fallbacks matter.
        assert(FileManager.default.fileExists(atPath: afconvert.path),
               "afconvert missing — audio conversion has no backend")
        // A missing tool must be a thrown error, never a crash or a silent success.
        do {
            _ = try run(URL(filePath: "/usr/bin/definitely-not-a-tool"), [])
            assertionFailure("running a missing tool must throw")
        } catch {
            assert(error is ShellError)
        }
        // Arguments survive spaces and quotes intact — the injection check.
        if let result = try? run(URL(filePath: "/bin/echo"), ["a b", "c\"d"]) {
            assert(result.stdout == "a b c\"d\n", "arguments must pass through unmangled")
        }
    }
}
