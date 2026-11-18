import Foundation

/// Runs a subprocess with a hard deadline. Output goes to a temp file (no pipe deadlocks),
/// the parent environment is always inherited, and the process is killed on timeout.
public enum BoundedProcess {
    public struct Result {
        public let status: Int32?   // nil => timed out / failed to launch
        public let output: String
        public let data: Data?
        public var success: Bool { status == 0 }
        public var timedOut: Bool { status == nil }

        public init(status: Int32?, output: String, data: Data? = nil) {
            self.status = status
            self.output = output
            self.data = data
        }
    }

    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        extraEnv: [String: String] = [:],
        timeout: TimeInterval
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd = cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\(extraPaths):\($0)" } ?? extraPaths
        env["GIT_TERMINAL_PROMPT"] = "0"
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nx_bp_\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let handle = try? FileHandle(forWritingTo: tmp) else {
            return Result(status: nil, output: "cannot create temp log")
        }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            try? handle.close()
            return Result(status: nil, output: error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(40_000) }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            usleep(300_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? handle.close()
        let rawData = try? Data(contentsOf: tmp)
        let out = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        return Result(status: timedOut ? nil : process.terminationStatus, output: out, data: rawData)
    }

    /// Runs a subprocess with live `\r`/`\n`-delimited output streaming and a hard watchdog deadline.
    /// Must only be called from a background queue.
    @discardableResult
    public static func runStreaming(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        extraEnv: [String: String] = [:],
        timeout: TimeInterval,
        onOutputLine: @escaping (String) -> Void
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd = cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\(extraPaths):\($0)" } ?? extraPaths
        env["GIT_TERMINAL_PROMPT"] = "0"
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let bufferLock = NSLock()
        var pendingBuffer = ""
        var fullOutput = ""
        var timedOut = false

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

            var emittedLines: [String] = []
            bufferLock.lock()
            fullOutput += chunk
            pendingBuffer += chunk
            let normalized = pendingBuffer.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let endsWithBreak = normalized.hasSuffix("\n")
            var parts = normalized.components(separatedBy: "\n")
            if endsWithBreak {
                pendingBuffer = ""
            } else {
                pendingBuffer = parts.popLast() ?? ""
            }
            emittedLines = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            bufferLock.unlock()

            for line in emittedLines {
                onOutputLine(line)
            }
        }

        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler { [weak process] in
            guard let proc = process, proc.isRunning else { return }
            bufferLock.lock()
            timedOut = true
            bufferLock.unlock()
            proc.terminate()
            usleep(300_000)
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
        watchdog.resume()

        do {
            try process.run()
        } catch {
            watchdog.cancel()
            handle.readabilityHandler = nil
            return Result(status: nil, output: error.localizedDescription)
        }

        process.waitUntilExit()
        watchdog.cancel()
        handle.readabilityHandler = nil

        let remData = handle.readDataToEndOfFile()
        if !remData.isEmpty, let remText = String(data: remData, encoding: .utf8) {
            bufferLock.lock()
            fullOutput += remText
            pendingBuffer += remText
            bufferLock.unlock()
        }

        var finalTrailing = ""
        var didTimeout = false
        bufferLock.lock()
        finalTrailing = pendingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBuffer = ""
        didTimeout = timedOut
        let outputSnapshot = fullOutput
        bufferLock.unlock()

        if !finalTrailing.isEmpty {
            onOutputLine(finalTrailing)
        }

        return Result(status: didTimeout ? nil : process.terminationStatus, output: outputSnapshot)
    }

    /// Runs `xcrun devicectl <args>` using `--json-output <tempFile>` so human-readable tables or warnings
    /// on stdout/stderr never corrupt structured JSON parsing.
    public static func runDevicectlJson(
        _ devicectlArgs: [String],
        timeout: TimeInterval
    ) -> (result: Result, json: [String: Any]?) {
        let tmpJson = FileManager.default.temporaryDirectory
            .appendingPathComponent("nx_dc_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpJson) }

        var args = ["devicectl"]
        args.append(contentsOf: devicectlArgs)
        args.append(contentsOf: ["--json-output", tmpJson.path])

        let res = run("/usr/bin/xcrun", args, timeout: timeout)
        if let fileData = try? Data(contentsOf: tmpJson),
           !fileData.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] {
            return (res, obj)
        }
        if let fallback = extractJsonDictionary(from: res.output) {
            return (res, fallback)
        }
        return (res, nil)
    }

    /// Extracts a root JSON dictionary from potentially noisy CLI output (first `{` to last `}`).
    public static func extractJsonDictionary(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end,
              let data = String(text[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    public static func gitPath() -> String {
        ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
            .first(where: { FileManager.default.fileExists(atPath: $0) }) ?? "/usr/bin/git"
    }
}
