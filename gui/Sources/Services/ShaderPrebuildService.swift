import Foundation
import AppKit

public enum ShaderCacheStatus: Equatable {
    case alreadyOptimized(basesCount: Int)
    case needsPrebuild(totalPairs: Int)
    case notApplicable
}

/// Service dedicated to detecting, monitoring, and prebuilding Metal 4 shader pipeline bases
/// for ported Nintendo Switch games, preventing user-facing black screen stalls on launch.
public final class ShaderPrebuildService: ObservableObject {
    public static let shared = ShaderPrebuildService()

    // Real-time launch monitoring state
    @Published public var isPrebuilding: Bool = false
    @Published public var activeGameId: UUID? = nil
    @Published public var activeGameName: String = ""
    @Published public var currentPairs: Int = 0
    @Published public var totalPairs: Int = 0
    @Published public var progress: Double = 0.0

    // Interrupted alert state
    @Published public var showInterruptedAlert: Bool = false
    @Published public var interruptedGame: PortedGame? = nil
    @Published public var interruptedCurrentPairs: Int = 0
    @Published public var interruptedTotalPairs: Int = 0

    // Manual/Headless prebuild state
    @Published public var isRunningHeadlessPrebuild: Bool = false
    @Published public var headlessPrebuildProgress: Double = 0.0
    @Published public var headlessCurrentPairs: Int = 0
    @Published public var headlessTotalPairs: Int = 0
    @Published public var headlessStatusMessage: String = ""

    private var monitoringTimer: Timer? = nil
    private var lastObservedFileSize: UInt64 = 0
    private var activeMonitoringGameId: UUID? = nil
    private var activeMonitoringLogURL: URL? = nil
    private var prebuildDoneDetected: Bool = false
    private var headlessProcess: Process? = nil

    private init() {}

    // MARK: - Status Checking

    public func checkShaderStatus(for game: PortedGame) -> ShaderCacheStatus {
        guard game.platform == .macApp else {
            return .notApplicable
        }
        
        let dmDir = game.url.appendingPathComponent("Contents/Resources/dm")
        let shaderPairsURL = dmDir.appendingPathComponent("shader_pairs.tsv")
        guard FileManager.default.fileExists(atPath: shaderPairsURL.path) else {
            return .notApplicable
        }
        
        let total = countShaderPairs(at: shaderPairsURL)
        guard total > 0 else { return .notApplicable }
        
        let titleId = game.titleId ?? ""
        guard !titleId.isEmpty else { return .needsPrebuild(totalPairs: total) }
        
        // 1. Check user cache folder
        let userArchiveDir = SystemDetector.shared.appSupportDirectory
            .appendingPathComponent(titleId)
            .appendingPathComponent("pso_archive")
        let userPrebuiltTSV = userArchiveDir.appendingPathComponent("prebuilt.tsv")
        
        if FileManager.default.fileExists(atPath: userPrebuiltTSV.path) {
            if let files = try? FileManager.default.contentsOfDirectory(at: userArchiveDir, includingPropertiesForKeys: nil) {
                let mtlFiles = files.filter { $0.pathExtension == "mtl4a" }
                if !mtlFiles.isEmpty {
                    return .alreadyOptimized(basesCount: total)
                }
            }
        }
        
        // 2. Check bundled archive
        let bundlePsoDir = game.url.appendingPathComponent("Contents/Resources/pso")
        let bundlePrebuiltTSV = bundlePsoDir.appendingPathComponent("prebuilt.tsv")
        if FileManager.default.fileExists(atPath: bundlePrebuiltTSV.path) {
            let isDepthZeroGame = (titleId == "0400A3A01EE4C000") // Pokopia
            if let content = try? String(contentsOf: bundlePrebuiltTSV, encoding: .utf8) {
                if isDepthZeroGame && content.contains("depth\tnear=0") {
                    return .alreadyOptimized(basesCount: total)
                } else if !isDepthZeroGame && content.contains("depth\tnear=-w") {
                    return .alreadyOptimized(basesCount: total)
                }
            }
        }
        
        return .needsPrebuild(totalPairs: total)
    }

    private func countShaderPairs(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        var count = 0
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let len = raw.count
            var lineStart = 0
            for i in 0..<len {
                if ptr[i] == 10 { // \n
                    if lineStart < len && ptr[lineStart] != 35 { // not '#'
                        count += 1
                    }
                    lineStart = i + 1
                }
            }
            if lineStart < len && ptr[lineStart] != 35 {
                count += 1
            }
        }
        return count
    }

    // MARK: - Launch Monitoring

    public func startMonitoringLaunch(game: PortedGame) {
        guard game.platform == .macApp else { return }
        let titleId = game.titleId ?? ""
        guard !titleId.isEmpty else { return }
        
        stopMonitoring()
        
        let logURL = SystemDetector.shared.logsDirectory.appendingPathComponent("\(titleId).log")
        activeMonitoringGameId = game.id
        activeMonitoringLogURL = logURL
        activeGameId = game.id
        activeGameName = game.name
        prebuildDoneDetected = false
        lastObservedFileSize = 0
        currentPairs = 0
        totalPairs = 0
        progress = 0.0
        
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.pollLog()
        }
    }

    public func onGameTerminated(game: PortedGame) {
        if isPrebuilding && activeMonitoringGameId == game.id && !prebuildDoneDetected {
            interruptedGame = game
            interruptedCurrentPairs = currentPairs
            interruptedTotalPairs = totalPairs > 0 ? totalPairs : 17952
            showInterruptedAlert = true
            SoundEffectService.shared.play(.error)
        }
        stopMonitoring()
    }

    public func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        activeMonitoringGameId = nil
        activeMonitoringLogURL = nil
        isPrebuilding = false
    }

    private func pollLog() {
        guard let logURL = activeMonitoringLogURL, FileManager.default.fileExists(atPath: logURL.path) else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64 else { return }
        
        guard size > lastObservedFileSize else { return }
        
        guard let fileHandle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? fileHandle.close() }
        
        let readLength = min(size, 32768)
        let offset = size - readLength
        fileHandle.seek(toFileOffset: offset)
        let data = fileHandle.readDataToEndOfFile()
        lastObservedFileSize = size
        
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            if line.contains("pipeline prebuild done:") {
                prebuildDoneDetected = true
                if isPrebuilding {
                    isPrebuilding = false
                    progress = 1.0
                    let name = activeGameName
                    NotificationService.shared.sendShaderOptimizationComplete(gameName: name)
                    SoundEffectService.shared.play(.launch)
                }
            } else if line.contains("pipeline prebuild:") {
                parsePrebuildProgress(from: line)
            }
        }
    }

    private func parsePrebuildProgress(from line: String) {
        // Pattern 1: pipeline prebuild: 5000 of 17952 pairs, ...
        if let ofRange = line.range(of: " of ") {
            let prefix = line[..<ofRange.lowerBound]
            let suffix = line[ofRange.upperBound...]
            
            if let colonRange = prefix.range(of: "pipeline prebuild:", options: .backwards) {
                let doneStr = prefix[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if let pairsRange = suffix.range(of: " pairs") {
                    let totalStr = suffix[..<pairsRange.lowerBound].trimmingCharacters(in: .whitespaces)
                    if let done = Int(doneStr), let total = Int(totalStr), total > 0 {
                        currentPairs = done
                        totalPairs = total
                        progress = min(1.0, max(0.0, Double(done) / Double(total)))
                        isPrebuilding = true
                    }
                }
            }
        } else if let pairsRange = line.range(of: " shader pairs") {
            // Pattern 2: pipeline prebuild: 17952 shader pairs of ...
            if let colonRange = line.range(of: "pipeline prebuild:") {
                let totalStr = line[colonRange.upperBound..<pairsRange.lowerBound].trimmingCharacters(in: .whitespaces)
                if let total = Int(totalStr), total > 0 {
                    totalPairs = total
                    isPrebuilding = true
                }
            }
        }
    }

    // MARK: - Headless Background Prebuilder

    public func prebuildShadersHeadless(for game: PortedGame, completion: ((Bool, String?) -> Void)? = nil) {
        guard !isRunningHeadlessPrebuild else {
            completion?(false, "A shader prebuild is already in progress.")
            return
        }
        
        let hostExe = game.url.appendingPathComponent("Contents/MacOS/nxnative")
        let fallbackHost = game.url.appendingPathComponent("Contents/MacOS/dmhost")
        let targetExe = FileManager.default.fileExists(atPath: hostExe.path) ? hostExe : fallbackHost
        
        guard FileManager.default.fileExists(atPath: targetExe.path) else {
            completion?(false, "Executable not found inside game bundle.")
            return
        }
        
        isRunningHeadlessPrebuild = true
        headlessPrebuildProgress = 0.0
        headlessCurrentPairs = 0
        headlessTotalPairs = 0
        headlessStatusMessage = LocalizationService.shared.format(key: "shader.prebuild_active_desc", arguments: [game.name])
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            self?.headlessProcess = process
            process.executableURL = targetExe
            
            var env = ProcessInfo.processInfo.environment
            env["DM_PSO_PREBUILD"] = "tool"
            env["DM_WINDOW"] = "0"
            env["DM_AUDIO"] = "0"
            env["NXNATIVE_DATA_DIR"] = SystemDetector.shared.appSupportDirectory.path
            env["NXNATIVE_LOGS_DIR"] = SystemDetector.shared.logsDirectory.path
            
            let titleId = game.titleId ?? ""
            if titleId == "0400A3A01EE4C000" { // Pokopia depth_mode zero
                env["DM_PSO_PREBUILD_DEPTH"] = "zero"
            }
            
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.handleHeadlessOutput(str)
                }
            }
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let success = (process.terminationStatus == 0)
                DispatchQueue.main.async {
                    self?.isRunningHeadlessPrebuild = false
                    self?.headlessProcess = nil
                    pipe.fileHandleForReading.readabilityHandler = nil
                    
                    if success {
                        self?.headlessPrebuildProgress = 1.0
                        SoundEffectService.shared.play(.launch)
                        NotificationService.shared.sendShaderOptimizationComplete(gameName: game.name)
                        completion?(true, nil)
                    } else {
                        SoundEffectService.shared.play(.error)
                        completion?(false, "Process exited with code \(process.terminationStatus)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isRunningHeadlessPrebuild = false
                    self?.headlessProcess = nil
                    pipe.fileHandleForReading.readabilityHandler = nil
                    SoundEffectService.shared.play(.error)
                    completion?(false, error.localizedDescription)
                }
            }
        }
    }

    private func handleHeadlessOutput(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("pipeline prebuild done:") {
                headlessPrebuildProgress = 1.0
            } else if line.contains("pipeline prebuild:") {
                if let ofRange = line.range(of: " of ") {
                    let prefix = line[..<ofRange.lowerBound]
                    let suffix = line[ofRange.upperBound...]
                    if let colonRange = prefix.range(of: "pipeline prebuild:", options: .backwards),
                       let pairsRange = suffix.range(of: " pairs") {
                        let doneStr = prefix[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
                        let totalStr = suffix[..<pairsRange.lowerBound].trimmingCharacters(in: .whitespaces)
                        if let done = Int(doneStr), let total = Int(totalStr), total > 0 {
                            headlessCurrentPairs = done
                            headlessTotalPairs = total
                            headlessPrebuildProgress = min(1.0, max(0.0, Double(done) / Double(total)))
                        }
                    }
                }
            }
        }
    }

    public func cancelHeadlessPrebuild() {
        headlessProcess?.terminate()
        headlessProcess = nil
        isRunningHeadlessPrebuild = false
    }
}
