import Foundation

public final class PatchService {
    public static let shared = PatchService()
    private static let ootTitleId = "0400486024DEC000"
    
    private init() {}
    
    public func checkPatchStatuses(nxnativePath: String) -> [EnginePatchItem] {
        let root = URL(fileURLWithPath: nxnativePath)
        let fm = FileManager.default
        
        return EnginePatchRegistry.patches.map { def in
            let fileURL = root.appendingPathComponent(def.relativePath)
            guard fm.fileExists(atPath: fileURL.path),
                  let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return EnginePatchItem(id: def.id, name: def.name, summary: def.summary, relativePath: def.relativePath, isApplied: false)
            }
            let applied = content.contains(def.checkToken)
            return EnginePatchItem(id: def.id, name: def.name, summary: def.summary, relativePath: def.relativePath, isApplied: applied)
        }
    }
    
    /// Restores files left in an unmerged conflict state (e.g., interrupted stash pop or git pull)
    /// back to clean HEAD so compatibility patches can be reliably reapplied without syntax errors.
    @discardableResult
    public func repairUnmergedFiles(nxnativePath: String) -> [String] {
        let fm = FileManager.default
        let repoURL = URL(fileURLWithPath: nxnativePath)
        guard fm.fileExists(atPath: repoURL.appendingPathComponent(".git").path) else {
            return []
        }
        
        let gitPath = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"].first(where: { fm.fileExists(atPath: $0) }) ?? "/usr/bin/git"
        
        func runGit(_ args: [String], timeoutSeconds: Double = 2.0) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gitPath)
            p.arguments = ["-C", nxnativePath] + args
            p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            
            do {
                try p.run()
            } catch {
                return nil
            }
            
            let deadline = DispatchTime.now() + timeoutSeconds
            let sema = DispatchSemaphore(value: 0)
            var outputData = Data()
            
            DispatchQueue.global(qos: .utility).async {
                outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                sema.signal()
            }
            
            if sema.wait(timeout: deadline) == .timedOut {
                p.terminate()
                return nil
            }
            
            return String(data: outputData, encoding: .utf8)
        }
        
        guard let output = runGit(["diff", "--name-only", "--diff-filter=U"]) else {
            return []
        }
        
        let files = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !files.isEmpty else { return [] }
        
        // Batch restoration of conflicted files in two bounded commands
        _ = runGit(["checkout", "HEAD", "--"] + files)
        _ = runGit(["reset", "-q", "HEAD", "--"] + files)
        
        return files
    }
    
    /// Removes duplicate copy_t2t_draw_sq / copy_t2t_draw wrapper definitions left by earlier patcher runs.
    @discardableResult
    public func repairCorruptedNvnMtlIfNeeded(
        nxnativePath: String,
        logger: ((String, Bool) -> Void)? = nil
    ) -> Bool {
        let nvnURL = URL(fileURLWithPath: nxnativePath).appendingPathComponent("dm/gfx/nvn/nvn_mtl.m")
        guard let content = try? String(contentsOf: nvnURL, encoding: .utf8) else { return false }

        let poisonedBlock = """

static int copy_t2t_draw_sq(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror, int square) {
    return copy_t2t_draw_x(s, d, sl, ss, dl, ds, sr, dr, linear, mirror, square, 0);
}
static int copy_t2t_draw(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror) {
    return copy_t2t_draw_x(s, d, sl, ss, dl, ds, sr, dr, linear, mirror, 0, 0);
}
"""
        guard content.contains("static inline int copy_t2t_draw_sq("),
              content.contains(poisonedBlock) else {
            return false
        }

        let repaired = content.replacingOccurrences(of: poisonedBlock, with: "")
        guard repaired != content else { return false }
        do {
            try repaired.write(to: nvnURL, atomically: true, encoding: .utf8)
            logger?("[Patch] Auto-healed duplicate copy_t2t_draw wrappers in dm/gfx/nvn/nvn_mtl.m", true)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func applyPatchesIfNeeded(
        nxnativePath: String,
        includeOotPatches: Bool = false,
        logger: ((String, Bool) -> Void)? = nil
    ) -> (applied: Int, skipped: Int, errors: [String]) {
        let root = URL(fileURLWithPath: nxnativePath)
        let fm = FileManager.default
        
        var appliedCount = 0
        var skippedCount = 0
        var errorMessages: [String] = []
        
        let repaired = repairUnmergedFiles(nxnativePath: nxnativePath)
        for f in repaired {
            logger?("[Repo] Restored \(f) from upstream (resolved merge conflict)", true)
        }

        if repairCorruptedNvnMtlIfNeeded(nxnativePath: nxnativePath, logger: logger) {
            appliedCount += 1
        }

        // Strictly isolate scripts/apply_oot_patches.py to Zelda: Ocarina of Time (0400486024DEC000) builds
        if includeOotPatches {
            let ootResult = runOotPatchScript(nxnativePath: nxnativePath, apply: true)
            if let msg = ootResult.message {
                logger?(msg, ootResult.repaired)
            }
            if !ootResult.ok, let err = ootResult.error {
                errorMessages.append(err)
            }
        }
        
        for def in EnginePatchRegistry.patches {
            if !includeOotPatches && def.id.hasPrefix("oot_") {
                continue
            }
            let fileURL = root.appendingPathComponent(def.relativePath)
            guard fm.fileExists(atPath: fileURL.path) else {
                let msg = "Skipped \(def.name): file not found at \(def.relativePath)"
                logger?(msg, false)
                continue
            }
            
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                let msg = "Error reading \(def.relativePath)"
                errorMessages.append(msg)
                logger?(msg, false)
                continue
            }
            
            // If already contains token, it's either merged upstream or previously applied
            if content.contains(def.checkToken) {
                // Self-heal: if global_60fps_speed_sync was previously applied without the weak declaration of dm_fps_has_engine_lock, inject it now
                if def.id == "global_60fps_speed_sync" && !content.contains("int dm_fps_has_engine_lock(void)") {
                    let weakDecl = "__attribute__((weak)) int dm_fps_has_engine_lock(void) { return 0; }\n\nstatic int speed_sync_on(void)"
                    if content.contains("static int speed_sync_on(void)") {
                        let healed = content.replacingOccurrences(of: "static int speed_sync_on(void)", with: weakDecl)
                        try? healed.write(to: fileURL, atomically: true, encoding: .utf8)
                        appliedCount += 1
                        logger?("[Patch] Repaired missing weak declaration in \(def.relativePath)", true)
                        continue
                    }
                }
                skippedCount += 1
                logger?("[Patch] \(def.name): Already applied or upstream merged.", false)
                continue
            }
            
            // Perform non-destructive transformation
            guard let modified = def.applyTransform(content) else {
                let msg = "[Patch] Warning: Pattern anchor not found for \(def.name) in \(def.relativePath)"
                errorMessages.append(msg)
                logger?(msg, false)
                continue
            }
            
            do {
                try modified.write(to: fileURL, atomically: true, encoding: .utf8)
                appliedCount += 1
                logger?("[Patch] Successfully applied: \(def.name)", true)
            } catch {
                let msg = "[Patch] Failed to write \(def.relativePath): \(error.localizedDescription)"
                errorMessages.append(msg)
                logger?(msg, false)
            }
        }
        
        return (appliedCount, skippedCount, errorMessages)
    }

    /// Executes scripts/apply_oot_patches.py with a strict timeout so Zelda OoT hooks remain intact after any merge.
    public func runOotPatchScript(
        nxnativePath: String,
        apply: Bool = true
    ) -> (ok: Bool, repaired: Bool, message: String?, error: String?) {
        let fm = FileManager.default
        let scriptPath = URL(fileURLWithPath: nxnativePath).appendingPathComponent("scripts/apply_oot_patches.py").path
        guard fm.fileExists(atPath: scriptPath) else {
            return (true, false, nil, nil)
        }

        let pythonPath = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first(where: { fm.fileExists(atPath: $0) }) ?? "/usr/bin/python3"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.currentDirectoryURL = URL(fileURLWithPath: nxnativePath)
        p.arguments = [scriptPath] + (apply ? ["--apply", "--soft"] : ["--check"])
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        do {
            try p.run()
        } catch {
            return (false, false, nil, "[OoT Patch] Could not launch apply_oot_patches.py: \(error.localizedDescription)")
        }

        let sema = DispatchSemaphore(value: 0)
        var outData = Data()
        DispatchQueue.global(qos: .utility).async {
            outData = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            sema.signal()
        }

        if sema.wait(timeout: .now() + 5.0) == .timedOut {
            p.terminate()
            return (false, false, nil, "[OoT Patch] Timed out running apply_oot_patches.py")
        }

        let text = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus != 0 {
            let summary = text.isEmpty ? "exit code \(p.terminationStatus)" : text
            return (false, false, nil, "[OoT Patch] Verification failed: \(summary)")
        }
        let repaired = text.contains("[REPAIRED]")
        let hasWarn = text.contains("[OOT-PATCH-WARN]")
        let msg: String
        if repaired {
            msg = "[OoT Patch] Restored isolated Zelda: Ocarina of Time enhancements."
        } else if hasWarn {
            msg = "[OoT Patch] Core engine enhancements verified (some optional shaders bypassed for compatibility)."
        } else {
            msg = "[OoT Patch] Zelda: Ocarina of Time enhancements verified intact."
        }
        return (true, repaired, msg, nil)
    }
}
