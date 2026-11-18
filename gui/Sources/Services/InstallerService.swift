import Foundation

public protocol InstallerServiceDelegate: AnyObject {
    func installerDidProduceOutput(_ line: String)
    func installerDidStartItem(_ name: String)
    func installerDidFinishItem(_ name: String, success: Bool)
    func installerDidCompleteAll(allSuccess: Bool)
}

public final class InstallerService {
    public static let shared = InstallerService()
    
    public weak var delegate: InstallerServiceDelegate?
    private let stateLock = NSLock()
    private var isRunning = false
    private var currentProcess: Process?
    private var activeTimeoutSeconds: TimeInterval = 600.0
    
    private init() {}
    
    public func install(dependency: DependencyStatus, completion: @escaping (Bool) -> Void) {
        guard let cmd = dependency.installCommand, !cmd.isEmpty, beginRun() else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        executeAction(itemName: dependency.name, logTitle: "Installing: \(dependency.name)", command: cmd, completion: completion)
    }
    
    public func repair(dependency: DependencyStatus, completion: @escaping (Bool) -> Void) {
        guard let cmd = dependency.repairCommand ?? dependency.installCommand, !cmd.isEmpty, beginRun() else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        executeAction(itemName: dependency.name, logTitle: "Repairing: \(dependency.name)", command: cmd, completion: completion)
    }
    
    public func uninstall(dependency: DependencyStatus, completion: @escaping (Bool) -> Void) {
        guard !dependency.isProtected else {
            emitOutput("[WARN] \(dependency.name) is an essential system tool and cannot be uninstalled.")
            DispatchQueue.main.async { completion(false) }
            return
        }
        guard let cmd = dependency.uninstallCommand, !cmd.isEmpty, beginRun() else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        executeAction(itemName: dependency.name, logTitle: "Uninstalling: \(dependency.name)", command: cmd, completion: completion)
    }

    private func beginRun() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    private func endRun() {
        stateLock.lock()
        isRunning = false
        currentProcess = nil
        stateLock.unlock()
    }

    private func emitOutput(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.installerDidProduceOutput(text)
        }
    }

    private func notifyStartItem(_ name: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.installerDidStartItem(name)
        }
    }

    private func notifyFinishItem(_ name: String, success: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.installerDidFinishItem(name, success: success)
        }
    }

    private func notifyCompleteAll(_ allSuccess: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.installerDidCompleteAll(allSuccess: allSuccess)
        }
    }
    
    private func executeAction(itemName: String, logTitle: String, command: String, completion: @escaping (Bool) -> Void) {
        notifyStartItem(itemName)
        emitOutput("==> \(logTitle)")
        emitOutput("Command: \(command)")
        
        runShell(command: command, timeoutSeconds: activeTimeoutSeconds) { [weak self] success, _ in
            self?.endRun()
            self?.notifyFinishItem(itemName, success: success)
            self?.notifyCompleteAll(success)
            DispatchQueue.main.async { completion(success) }
        }
    }
    
    public func installAll(dependencies: [DependencyStatus], completion: @escaping (Bool) -> Void) {
        let ordered = SystemPrerequisites.ordered(dependencies)
        var queue = ordered.filter { ($0.installCommand ?? "").isEmpty == false }
        guard !queue.isEmpty else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        guard beginRun() else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        
        let totalSteps = queue.count
        var overallSuccess = true
        
        func processNext() {
            guard !queue.isEmpty else {
                self.endRun()
                self.notifyCompleteAll(overallSuccess)
                DispatchQueue.main.async { completion(overallSuccess) }
                return
            }
            
            let item = queue.removeFirst()
            let currentStep = totalSteps - queue.count
            self.notifyStartItem("\(item.name) (\(currentStep)/\(totalSteps))")
            self.emitOutput("\n----------------------------------------")
            self.emitOutput("==> Installing (\(currentStep)/\(totalSteps)): \(item.name)")
            self.emitOutput("Command: \(item.installCommand!)")
            
            self.runShell(command: item.installCommand!, timeoutSeconds: self.activeTimeoutSeconds) { [weak self] success, _ in
                guard let self = self else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                if !success {
                    overallSuccess = false
                    self.emitOutput("[FAIL] Failed to install \(item.name).")
                } else {
                    self.emitOutput("[OK] \(item.name) installed successfully.")
                }
                self.notifyFinishItem(item.name, success: success)
                processNext()
            }
        }
        
        processNext()
    }
    
    public func repairAll(dependencies: [DependencyStatus], completion: @escaping (Bool) -> Void) {
        let ordered = SystemPrerequisites.ordered(dependencies)
        var queue = ordered.filter { ($0.repairCommand ?? $0.installCommand ?? "").isEmpty == false }
        guard !queue.isEmpty else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        guard beginRun() else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        
        var overallSuccess = true
        
        func processNext() {
            guard !queue.isEmpty else {
                self.endRun()
                self.notifyCompleteAll(overallSuccess)
                DispatchQueue.main.async { completion(overallSuccess) }
                return
            }
            
            let item = queue.removeFirst()
            let cmd = item.repairCommand ?? item.installCommand!
            self.notifyStartItem(item.name)
            self.emitOutput("\n----------------------------------------")
            self.emitOutput("==> Repairing: \(item.name)")
            self.emitOutput("Command: \(cmd)")
            
            self.runShell(command: cmd, timeoutSeconds: self.activeTimeoutSeconds) { [weak self] success, _ in
                guard let self = self else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                if !success {
                    overallSuccess = false
                    self.emitOutput("[FAIL] Failed to repair \(item.name).")
                } else {
                    self.emitOutput("[OK] \(item.name) repaired successfully.")
                }
                self.notifyFinishItem(item.name, success: success)
                processNext()
            }
        }
        
        processNext()
    }
    
    private func runShell(command: String, timeoutSeconds: TimeInterval, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            
            var env = ProcessInfo.processInfo.environment
            let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            if let existing = env["PATH"] {
                env["PATH"] = "\(extraPaths):\(existing)"
            } else {
                env["PATH"] = extraPaths
            }
            
            // Configure SUDO_ASKPASS for unattended / GUI password prompts if required
            let askPassURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nxnative_askpass.sh")
            let askPassScript = """
            #!/bin/bash
            exec osascript -e 'display dialog "NxNative Launcher requires administrator privileges to install dependencies.\\n\\nPlease enter your macOS administrator password:" default answer "" with hidden answer with icon caution with title "NxNative Launcher"' -e 'text returned of result'
            """
            try? askPassScript.write(to: askPassURL, atomically: true, encoding: .utf8)
            chmod(askPassURL.path, 0o755)
            env["SUDO_ASKPASS"] = askPassURL.path
            process.environment = env
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            self?.stateLock.lock()
            self?.currentProcess = process
            self?.stateLock.unlock()
            
            let handle = pipe.fileHandleForReading
            let outputLock = NSLock()
            var fullOutput = ""
            var timedOut = false
            
            handle.readabilityHandler = { [weak self] h in
                let data = h.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                outputLock.lock()
                fullOutput += text
                outputLock.unlock()
                DispatchQueue.main.async {
                    self?.delegate?.installerDidProduceOutput(text.trimmingCharacters(in: .newlines))
                }
            }

            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            watchdog.schedule(deadline: .now() + timeoutSeconds)
            watchdog.setEventHandler { [weak process, weak self] in
                guard let proc = process, proc.isRunning else { return }
                timedOut = true
                proc.terminate()
                usleep(300_000)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                self?.emitOutput("[TIMEOUT] Step exceeded \(Int(timeoutSeconds))s limit and was terminated.")
            }
            watchdog.resume()
            
            do {
                try process.run()
                process.waitUntilExit()
                watchdog.cancel()
                handle.readabilityHandler = nil
                let remData = handle.readDataToEndOfFile()
                if !remData.isEmpty, let remText = String(data: remData, encoding: .utf8) {
                    outputLock.lock()
                    fullOutput += remText
                    outputLock.unlock()
                }
                
                outputLock.lock()
                let capturedOutput = fullOutput
                outputLock.unlock()

                var success = !timedOut && process.terminationStatus == 0
                if !timedOut && command.contains("xcode-select") && (capturedOutput.contains("install requested") || capturedOutput.contains("already installed")) {
                    success = true
                    self?.emitOutput("Apple installation dialog prompted on screen. Complete Apple's installer then click Re-check.")
                }
                DispatchQueue.main.async {
                    completion(success, capturedOutput)
                }
            } catch {
                watchdog.cancel()
                handle.readabilityHandler = nil
                DispatchQueue.main.async {
                    self?.emitOutput("Error running command: \(error.localizedDescription)")
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
}
