import Foundation

extension UpdateCheckerService {
    /// Ensures `origin` points to official GitLab (`rennan-group2/nxnative_Launcher`) for app updates,
    /// while preserving `seedds/nxnative` on GitHub as `upstream`.
    @discardableResult
    internal func ensureOfficialRemote(in nxnativePath: String, reportProgress: ((String) -> Void)? = nil) -> String {
        // 1. Ensure upstream points to seedds/nxnative (GitHub)
        let currentUpstream = runGit(["remote", "get-url", "upstream"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
        if currentUpstream.isEmpty {
            reportProgress?("==> Registering upstream remote (https://github.com/seedds/nxnative.git)...")
            _ = runGitWithStatus(["remote", "add", "upstream", Self.upstreamRepoURL], in: nxnativePath)
        } else if !currentUpstream.localizedCaseInsensitiveContains("seedds/nxnative") {
            _ = runGitWithStatus(["remote", "set-url", "upstream", Self.upstreamRepoURL], in: nxnativePath)
        }
        _ = runGitWithStatus(["config", "remote.upstream.fetch", "+refs/heads/*:refs/remotes/upstream/*"], in: nxnativePath)
        
        // 2. Ensure origin points to official GitLab repository
        let currentOrigin = runGit(["remote", "get-url", "origin"], in: nxnativePath).trimmingCharacters(in: .whitespacesAndNewlines)
        if currentOrigin.isEmpty {
            _ = runGitWithStatus(["remote", "add", "origin", Self.launcherRepoURL], in: nxnativePath)
            _ = runGitWithStatus(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], in: nxnativePath)
            return Self.launcherRepoURL
        }
        
        if !currentOrigin.localizedCaseInsensitiveContains("gitlab.com/rennan-group2/nxnative_Launcher") {
            // Migrate old GitHub/seedds origin remote to official GitLab
            reportProgress?("==> Migrating origin remote from GitHub to official GitLab (\(Self.launcherRepoURL))...")
            _ = runGitWithStatus(["remote", "set-url", "origin", Self.launcherRepoURL], in: nxnativePath)
        }
        _ = runGitWithStatus(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], in: nxnativePath)
        return currentOrigin.localizedCaseInsensitiveContains("gitlab.com/rennan-group2/nxnative_Launcher")
            ? currentOrigin
            : Self.launcherRepoURL
    }
    
    internal func syncUpdatedBundleToRunningAppIfNeeded(nxnativePath: String, reportProgress: (String) -> Void) {
        let fm = FileManager.default
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard currentBundleURL.pathExtension == "app" else { return }
        
        let workspaceRoot = URL(fileURLWithPath: nxnativePath).deletingLastPathComponent().standardizedFileURL
        let workspaceApp = workspaceRoot.appendingPathComponent("NxNative_Launcher.app").standardizedFileURL
        let repoApp = URL(fileURLWithPath: nxnativePath).appendingPathComponent("NxNative_Launcher.app").standardizedFileURL
        
        let sourceApp = fm.fileExists(atPath: workspaceApp.path) ? workspaceApp : repoApp
        if currentBundleURL.path != sourceApp.path && fm.fileExists(atPath: sourceApp.path) {
            reportProgress("==> Update prepared. Relaunch will safely update bundle at \(currentBundleURL.path)")
        }
    }
    
    /// Builds a subprocess environment that inherits the system environment, ensures `HOME` and fallback Git
    /// author/committer identities exist, and prepends standard Homebrew/system/Xcode toolchain paths.
    private func enrichedProcessEnvironment(extraPaths: String, extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let existingPath = env["PATH"], !existingPath.isEmpty {
            env["PATH"] = "\(extraPaths):\(existingPath)"
        } else {
            env["PATH"] = extraPaths
        }
        if (env["HOME"] ?? "").isEmpty {
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["GIT_AUTHOR_NAME"] = env["GIT_AUTHOR_NAME"] ?? "NxNative Updater"
        env["GIT_AUTHOR_EMAIL"] = env["GIT_AUTHOR_EMAIL"] ?? "updater@nxnative.local"
        env["GIT_COMMITTER_NAME"] = env["GIT_COMMITTER_NAME"] ?? "NxNative Updater"
        env["GIT_COMMITTER_EMAIL"] = env["GIT_COMMITTER_EMAIL"] ?? "updater@nxnative.local"
        for (k, v) in extra {
            env[k] = v
        }
        return env
    }

    internal func runShellScript(_ scriptPath: String, workingDir: String, onLine: @escaping (String) -> Void) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
        process.environment = enrichedProcessEnvironment(
            extraPaths: extraPaths,
            extra: [
                "EXISTING_APP_RESOURCES": Bundle.main.resourceURL?.path ?? "",
                "NXNATIVE_RUNNING_APP": Bundle.main.bundleURL.path
            ]
        )
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            chunk.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .forEach { onLine($0) }
        }
        
        do {
            try process.run()
            process.waitUntilExit()
            handle.readabilityHandler = nil
            return process.terminationStatus
        } catch {
            handle.readabilityHandler = nil
            onLine("Error running build script: \(error.localizedDescription)")
            return -1
        }
    }
    
    @discardableResult
    internal func runGitWithStatus(_ args: [String], in dir: String, timeout: TimeInterval = 15.0) -> (exitCode: Int32, output: String) {
        let fm = FileManager.default
        let gitPath = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"].first(where: { fm.fileExists(atPath: $0) }) ?? "/usr/bin/git"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let gitExtraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = enrichedProcessEnvironment(extraPaths: gitExtraPaths)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        let outputLock = NSLock()
        var outputData = Data()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if !chunk.isEmpty {
                outputLock.lock()
                outputData.append(chunk)
                outputLock.unlock()
            }
        }
        
        do {
            try process.run()
            
            // Watchdog deadline to ensure zero-hang on network or lock delays
            let dispatchGroup = DispatchGroup()
            dispatchGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                dispatchGroup.leave()
            }
            
            let waitResult = dispatchGroup.wait(timeout: .now() + timeout)
            if waitResult == .timedOut {
                if process.isRunning {
                    process.terminate()
                }
                handle.readabilityHandler = nil
                return (-1, "Git operation timed out after \(timeout)s: git \(args.joined(separator: " "))")
            }
            
            handle.readabilityHandler = nil
            let remaining = handle.readDataToEndOfFile()
            outputLock.lock()
            outputData.append(remaining)
            let outStr = String(data: outputData, encoding: .utf8) ?? ""
            outputLock.unlock()
            
            return (process.terminationStatus, outStr)
        } catch {
            handle.readabilityHandler = nil
            return (-1, error.localizedDescription)
        }
    }
    
    internal func runGit(_ args: [String], in dir: String, timeout: TimeInterval = 15.0) -> String {
        runGitWithStatus(args, in: dir, timeout: timeout).output
    }
}
