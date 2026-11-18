import Foundation

/// Shared USB AFC (`libimobiledevice`) and `devicectl` verification helpers for large iOS/iPadOS game assets.
public enum AppleAfcTransferService {
    private static let cacheLock = NSLock()
    private static var udidCache: [String: (udid: String?, expiresAt: Date)] = [:]

    /// Clears cached USB UDID lookups (e.g., if a cable was unplugged/replugged).
    public static func invalidateUDIDCache(for deviceId: String? = nil) {
        cacheLock.lock()
        if let id = deviceId {
            udidCache.removeValue(forKey: id)
        } else {
            udidCache.removeAll()
        }
        cacheLock.unlock()
    }

    /// Resolves the executable path for `afcclient` (Homebrew Apple Silicon, Intel, or bundled inside `.app`).
    public static func resolveAfcClientTool() -> String? {
        resolveTool("afcclient")
    }

    /// Resolves the executable path for `idevice_id`.
    public static func resolveIdeviceIdTool() -> String? {
        resolveTool("idevice_id")
    }

    /// Resolves the executable path for `ideviceinfo`.
    public static func resolveIdeviceInfoTool() -> String? {
        resolveTool("ideviceinfo")
    }

    private static func resolveTool(_ name: String) -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            BundledTools.tool(name) ?? ""
        ]
        for path in candidates where !path.isEmpty && fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Resolves the hardware USB UDID required by `afcclient`, or `nil` when only reachable over Wi-Fi.
    public static func resolveHardwareUDID(for device: ConnectedAppleDevice) -> String? {
        let now = Date()
        cacheLock.lock()
        if let cached = udidCache[device.id], cached.expiresAt > now {
            cacheLock.unlock()
            return cached.udid
        }
        cacheLock.unlock()

        func store(_ value: String?) -> String? {
            let ttl: TimeInterval = (value != nil) ? 15.0 : 1.0
            cacheLock.lock()
            udidCache[device.id] = (udid: value, expiresAt: Date().addingTimeInterval(ttl))
            cacheLock.unlock()
            return value
        }

        if let tool = resolveIdeviceIdTool() {
            let usbCheck = BoundedProcess.run(tool, ["-l"], timeout: 2.0)
            if usbCheck.success {
                let usbIds = usbCheck.output
                    .split(whereSeparator: \.isNewline)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if usbIds.isEmpty {
                    // Device is not connected via USB; skip pointless AFC attempts and slow devicectl details.
                    return store(nil)
                }
                if usbIds.contains(device.id) { return store(device.id) }
                if usbIds.count == 1 { return store(usbIds[0]) }

                // Multiple USB devices connected: resolve hardware UDID matching device.id
                let (_, json) = BoundedProcess.runDevicectlJson(
                    ["device", "info", "details", "--device", device.id],
                    timeout: 3.5
                )
                if let result = json?["result"] as? [String: Any],
                   let hw = result["hardwareProperties"] as? [String: Any],
                   let udid = hw["udid"] as? String,
                   usbIds.contains(udid) {
                    return store(udid)
                }
                return store(nil)
            }
        }

        let (_, json) = BoundedProcess.runDevicectlJson(
            ["device", "info", "details", "--device", device.id],
            timeout: 3.5
        )
        if let result = json?["result"] as? [String: Any],
           let hw = result["hardwareProperties"] as? [String: Any],
           let udid = hw["udid"] as? String,
           !udid.isEmpty {
            return store(udid)
        }

        return store(device.id.contains("0000") ? device.id : nil)
    }

    private static func parseAfcFileSize(_ output: String) -> Int64? {
        if let json = BoundedProcess.extractJsonDictionary(from: output) {
            if let val = json["st_size"] as? Int64 { return val }
            if let num = json["st_size"] as? NSNumber { return num.int64Value }
            if let str = json["st_size"] as? String, let val = Int64(str) { return val }
        }
        for line in output.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("st_size:"),
               let val = Int64(s.replacingOccurrences(of: "st_size:", with: "").trimmingCharacters(in: .whitespaces)) {
                return val
            }
        }
        return nil
    }

    private static func isAfcConfirmedMissing(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("object_not_found")
            || lower.contains("no such file")
            || lower.contains("stat failed")
    }

    /// Queries free bytes on the connected iOS device via USB AFC `devinfo` or `ideviceinfo`.
    public static func queryFreeStorageBytes(for device: ConnectedAppleDevice) -> Int64? {
        guard device.isAvailable, let udid = resolveHardwareUDID(for: device) else { return nil }

        if let afcPath = resolveAfcClientTool() {
            let res = BoundedProcess.run(afcPath, ["-u", udid, "--", "devinfo"], timeout: 4.0)
            if let json = BoundedProcess.extractJsonDictionary(from: res.output) {
                if let free = json["FSFreeBytes"] as? Int64 { return free }
                if let num = json["FSFreeBytes"] as? NSNumber { return num.int64Value }
            }
        }

        if let infoTool = resolveIdeviceInfoTool() {
            let res = BoundedProcess.run(
                infoTool,
                ["-u", udid, "-q", "com.apple.disk_usage", "-x"],
                timeout: 4.0
            )
            if res.success,
               let data = res.data ?? res.output.data(using: .utf8),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                if let free = plist["AmountDataAvailable"] as? Int64 { return free }
                if let num = plist["AmountDataAvailable"] as? NSNumber { return num.int64Value }
            }
        }

        return nil
    }

    /// Queries the exact byte size of a file inside the app container (USB AFC first, `devicectl` fallback).
    /// Returns `nil` when absent or unreachable.
    public static func checkContainerFileSize(
        bundleId: String,
        subdirectory: String,
        searchName: String,
        device: ConnectedAppleDevice
    ) -> Int64? {
        guard device.isAvailable else { return nil }

        if let afcPath = resolveAfcClientTool(),
           let udid = resolveHardwareUDID(for: device) {
            let trimmedSub = subdirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let afcTarget = trimmedSub.isEmpty ? "/\(searchName)" : "/\(trimmedSub)/\(searchName)"
            let infoRes = BoundedProcess.run(
                afcPath,
                ["-u", udid, "--container", bundleId, "--", "info", afcTarget],
                timeout: 4.0
            )
            if let sz = parseAfcFileSize(infoRes.output) {
                return sz
            }
            if isAfcConfirmedMissing(infoRes.output) {
                return nil
            }
        }

        let (res, json) = BoundedProcess.runDevicectlJson(
            [
                "device", "info", "files",
                "--device", device.id,
                "--domain-type", "appDataContainer",
                "--domain-identifier", bundleId,
                "--subdirectory", subdirectory,
                "--search", searchName
            ],
            timeout: 8.0
        )
        guard res.success,
              let result = json?["result"] as? [String: Any],
              let files = result["files"] as? [[String: Any]] else {
            return nil
        }

        for file in files {
            let name = (file["name"] as? String) ?? ""
            let leaf = (name as NSString).lastPathComponent
            if name.caseInsensitiveCompare(searchName) == .orderedSame || leaf.caseInsensitiveCompare(searchName) == .orderedSame {
                if let meta = file["metadata"] as? [String: Any] {
                    if let size = meta["size"] as? Int64 { return size }
                    if let num = meta["size"] as? NSNumber { return num.int64Value }
                }
                return 0
            }
        }
        return nil
    }

    /// Waits briefly after app install until iOS mounts the `appDataContainer` and exposes `Documents`.
    public static func waitForContainerReady(
        bundleId: String,
        device: ConnectedAppleDevice,
        timeoutSeconds: Double = 6.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let afcPath = resolveAfcClientTool(),
               let udid = resolveHardwareUDID(for: device) {
                let infoRes = BoundedProcess.run(
                    afcPath,
                    ["-u", udid, "--container", bundleId, "--", "info", "/Documents"],
                    timeout: 3.0
                )
                let lowerOut = infoRes.output.lowercased()
                let hasAfcError = lowerOut.contains("error:")
                    || lowerOut.contains("failed")
                    || lowerOut.contains("not present")
                if infoRes.success,
                   !hasAfcError,
                   let json = BoundedProcess.extractJsonDictionary(from: infoRes.output),
                   json["st_ifmt"] != nil {
                    return true
                }
            }

            let (res, json) = BoundedProcess.runDevicectlJson(
                [
                    "device", "info", "files",
                    "--device", device.id,
                    "--domain-type", "appDataContainer",
                    "--domain-identifier", bundleId,
                    "--subdirectory", ""
                ],
                timeout: 4.0
            )
            if res.success, json?["result"] != nil {
                return true
            }
            usleep(400_000)
        }
        return false
    }

    /// Removes a stale temporary or corrupted file inside the container when USB AFC is available.
    public static func removeContainerFileIfPresent(
        bundleId: String,
        subpath: String,
        device: ConnectedAppleDevice
    ) {
        guard let afcPath = resolveAfcClientTool(),
              let udid = resolveHardwareUDID(for: device) else {
            return
        }
        let afcTarget = subpath.hasPrefix("/") ? subpath : "/\(subpath)"
        _ = BoundedProcess.run(
            afcPath,
            ["-u", udid, "--container", bundleId, "--", "rm", afcTarget],
            timeout: 4.0
        )
    }

    /// Creates all intermediate directories for an AFC path (whether pointing to a directory or parent of a file).
    public static func ensureRemoteDirectories(
        afcPath: String,
        udid: String,
        domainId: String,
        afcPathToCreate: String,
        includesLeafDirectory: Bool
    ) {
        let normalized = afcPathToCreate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return }
        var components = normalized.split(separator: "/").map(String.init)
        if !includesLeafDirectory && !components.isEmpty {
            components.removeLast()
        }
        guard !components.isEmpty else { return }

        var current = ""
        for comp in components {
            current += "/\(comp)"
            _ = BoundedProcess.run(
                afcPath,
                ["-u", udid, "--container", domainId, "--", "mkdir", current],
                timeout: 3.0
            )
        }
    }

    /// Streams a file directly over USB via `afcclient` into `<destination>.part`, verifies `st_size`,
    /// atomically renames onto `<destination>`, and verifies destination `st_size` directly over AFC.
    public static func transferFileViaAfcClient(
        afcPath: String,
        udid: String,
        domainId: String,
        resolvedSourceURL: URL,
        destinationSubpath: String,
        expectedSize: Int64,
        device: ConnectedAppleDevice,
        onProcessChanged: ((Process?) -> Void)? = nil,
        onProgress: ((Double, String) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) -> Bool {
        let afcDest = destinationSubpath.hasPrefix("/") ? destinationSubpath : "/\(destinationSubpath)"
        let afcPart = "\(afcDest).part"
        let maxTimeoutSeconds = max(300.0, (Double(expectedSize) / (5.0 * 1024.0 * 1024.0)) + 180.0)

        ensureRemoteDirectories(
            afcPath: afcPath,
            udid: udid,
            domainId: domainId,
            afcPathToCreate: afcDest,
            includesLeafDirectory: false
        )
        // Remove any stale partial upload or mismatched file from an interrupted attempt before streaming.
        _ = BoundedProcess.run(afcPath, ["-u", udid, "--container", domainId, "--", "rm", afcPart], timeout: 4.0)

        onLog?("==> Sending via USB streaming (afcclient)...")

        let putRes = runBoundedCancellable(
            executable: afcPath,
            arguments: ["-u", udid, "--container", domainId, "--", "put", "-f", resolvedSourceURL.path, afcPart],
            maxTimeoutSeconds: maxTimeoutSeconds,
            stallTimeoutSeconds: 120.0,
            onProcessChanged: onProcessChanged,
            onProgress: onProgress
        )
        guard putRes.status == 0 else {
            invalidateUDIDCache(for: device.id)
            _ = BoundedProcess.run(afcPath, ["-u", udid, "--container", domainId, "--", "rm", afcPart], timeout: 5.0)
            return false
        }

        // afcclient may exit 0 even on internal errors; require exact st_size match on the staged .part file.
        let partInfoRes = BoundedProcess.run(
            afcPath,
            ["-u", udid, "--container", domainId, "--", "info", afcPart],
            timeout: 8.0
        )
        let partSize = parseAfcFileSize(partInfoRes.output)
        guard partSize == expectedSize else {
            _ = BoundedProcess.run(afcPath, ["-u", udid, "--container", domainId, "--", "rm", afcPart], timeout: 5.0)
            return false
        }

        _ = BoundedProcess.run(afcPath, ["-u", udid, "--container", domainId, "--", "rm", afcDest], timeout: 5.0)
        let mvRes = BoundedProcess.run(
            afcPath,
            ["-u", udid, "--container", domainId, "--", "mv", afcPart, afcDest],
            timeout: 8.0
        )
        guard mvRes.success else {
            _ = BoundedProcess.run(afcPath, ["-u", udid, "--container", domainId, "--", "rm", afcPart], timeout: 5.0)
            return false
        }

        // Verify final file size directly over AFC (<0.1s), avoiding slow flaky post-upload devicectl timeouts.
        let destInfoRes = BoundedProcess.run(
            afcPath,
            ["-u", udid, "--container", domainId, "--", "info", afcDest],
            timeout: 8.0
        )
        if parseAfcFileSize(destInfoRes.output) == expectedSize {
            return true
        }

        let destNS = destinationSubpath as NSString
        let verified = checkContainerFileSize(
            bundleId: domainId,
            subdirectory: destNS.deletingLastPathComponent,
            searchName: destNS.lastPathComponent,
            device: device
        )
        return verified == expectedSize
    }

    /// Recursively uploads a local directory (e.g., `manifest.json` + `save/`) directly over USB via `afcclient`.
    public static func transferDirectoryViaAfcClient(
        afcPath: String,
        udid: String,
        domainId: String,
        localDirectoryURL: URL,
        destinationSubpath: String,
        onLog: ((String) -> Void)? = nil
    ) -> Bool {
        let fm = FileManager.default
        let resolvedRoot = localDirectoryURL.resolvingSymlinksInPath()
        let baseAfcDir = "/" + destinationSubpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ensureRemoteDirectories(
            afcPath: afcPath,
            udid: udid,
            domainId: domainId,
            afcPathToCreate: baseAfcDir,
            includesLeafDirectory: true
        )

        guard let enumerator = fm.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return false
        }

        let rootPath = resolvedRoot.standardizedFileURL.path
        var createdDirs = Set<String>([baseAfcDir])
        var copiedFiles = 0

        for case let itemURL as URL in enumerator {
            let name = itemURL.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue }

            let stdPath = itemURL.standardizedFileURL.path
            guard stdPath.hasPrefix(rootPath) else { continue }
            var rel = String(stdPath.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            guard !rel.isEmpty else { continue }

            let remotePath = baseAfcDir == "/" ? "/\(rel)" : "\(baseAfcDir)/\(rel)"
            let vals = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])

            if vals?.isDirectory == true {
                if !createdDirs.contains(remotePath) {
                    ensureRemoteDirectories(
                        afcPath: afcPath,
                        udid: udid,
                        domainId: domainId,
                        afcPathToCreate: remotePath,
                        includesLeafDirectory: true
                    )
                    createdDirs.insert(remotePath)
                }
                continue
            }

            guard vals?.isRegularFile == true else { continue }
            let parentRemote = (remotePath as NSString).deletingLastPathComponent
            if !createdDirs.contains(parentRemote) {
                ensureRemoteDirectories(
                    afcPath: afcPath,
                    udid: udid,
                    domainId: domainId,
                    afcPathToCreate: parentRemote,
                    includesLeafDirectory: true
                )
                createdDirs.insert(parentRemote)
            }

            let fileSize = Int64(vals?.fileSize ?? 0)
            let putTimeout = max(30.0, (Double(fileSize) / (5.0 * 1024.0 * 1024.0)) + 20.0)
            var copiedSingleOk = false
            var lastAfcErr = ""
            for attempt in 1...2 {
                if attempt == 2 {
                    ensureRemoteDirectories(
                        afcPath: afcPath,
                        udid: udid,
                        domainId: domainId,
                        afcPathToCreate: parentRemote,
                        includesLeafDirectory: true
                    )
                    usleep(250_000)
                }
                let res = BoundedProcess.run(
                    afcPath,
                    ["-u", udid, "--container", domainId, "--", "put", "-f", itemURL.path, remotePath],
                    timeout: putTimeout
                )
                let lowerPut = res.output.lowercased()
                guard res.success, !lowerPut.contains("error:"), !lowerPut.contains("failed:") else {
                    lastAfcErr = res.output
                    continue
                }
                if fileSize > 0 {
                    let verify = BoundedProcess.run(
                        afcPath,
                        ["-u", udid, "--container", domainId, "--", "info", remotePath],
                        timeout: 6.0
                    )
                    if parseAfcFileSize(verify.output) != fileSize {
                        lastAfcErr = "AFC size mismatch on \(rel)"
                        continue
                    }
                }
                copiedSingleOk = true
                break
            }
            guard copiedSingleOk else {
                onLog?("[WARN] AFC failed copying \(rel): \(lastAfcErr)")
                return false
            }
            copiedFiles += 1
        }

        return copiedFiles > 0 || fm.fileExists(atPath: resolvedRoot.path)
    }

    private static func runBoundedCancellable(
        executable: String,
        arguments: [String],
        maxTimeoutSeconds: Double,
        stallTimeoutSeconds: Double,
        onProcessChanged: ((Process?) -> Void)?,
        onProgress: ((Double, String) -> Void)?
    ) -> BoundedProcess.Result {
        if onProcessChanged == nil && onProgress == nil {
            return BoundedProcess.run(executable, arguments, timeout: maxTimeoutSeconds)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\(extraPaths):\($0)" } ?? extraPaths
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice

        let stateLock = NSLock()
        var outputBuffer = ""
        var lastActivityTime = Date()
        var lastReportedPct = -1

        let pctRegex = try? NSRegularExpression(pattern: "([0-9]{1,3})%(?:\\s*\\(([^)]+)\\))?", options: [])

        let parseChunk: (Data) -> Void = { data in
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            stateLock.lock()
            lastActivityTime = Date()
            if outputBuffer.count < 64_000 {
                outputBuffer += chunk
            }
            stateLock.unlock()

            guard let onProgress else { return }
            let segments = chunk.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            for seg in segments {
                let trimmed = seg.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let regex = pctRegex else { continue }
                let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = regex.firstMatch(in: trimmed, range: nsRange),
                   let rPct = Range(match.range(at: 1), in: trimmed),
                   let pctVal = Int(trimmed[rPct]) {
                    let clamped = max(0, min(100, pctVal))
                    var speedText = ""
                    if match.numberOfRanges > 2,
                       match.range(at: 2).location != NSNotFound,
                       let rSpeed = Range(match.range(at: 2), in: trimmed) {
                        speedText = String(trimmed[rSpeed]).trimmingCharacters(in: .whitespaces)
                    }

                    stateLock.lock()
                    let shouldEmit = (clamped != lastReportedPct) || (clamped == 100 && !speedText.isEmpty)
                    if shouldEmit { lastReportedPct = clamped }
                    stateLock.unlock()

                    if shouldEmit {
                        let frac = Double(clamped) / 100.0
                        DispatchQueue.main.async {
                            onProgress(frac, speedText)
                        }
                    }
                }
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { handle in
            parseChunk(handle.availableData)
        }

        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return BoundedProcess.Result(status: nil, output: error.localizedDescription)
        }

        DispatchQueue.main.async { onProcessChanged?(proc) }

        let hardDeadline = Date().addingTimeInterval(maxTimeoutSeconds)
        var timedOut = false
        while proc.isRunning {
            let now = Date()
            stateLock.lock()
            let idleElapsed = now.timeIntervalSince(lastActivityTime)
            stateLock.unlock()

            if now >= hardDeadline || idleElapsed >= stallTimeoutSeconds {
                timedOut = true
                proc.terminate()
                usleep(300_000)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                break
            }
            usleep(40_000)
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        parseChunk(remaining)
        DispatchQueue.main.async { onProcessChanged?(nil) }

        stateLock.lock()
        let finalOutput = outputBuffer
        stateLock.unlock()
        return BoundedProcess.Result(status: timedOut ? nil : proc.terminationStatus, output: finalOutput)
    }
}
