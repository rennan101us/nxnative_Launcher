import Foundation

extension SystemDetector {
    public func checkPrerequisites() -> SystemPrerequisites {
        var prereqs = SystemPrerequisites()
        let fm = FileManager.default
        
        // 1. Xcode & Command Line Tools
        let xcodeRes = runQuickCommand("/usr/bin/xcode-select", args: ["-p"])
        let hasXcodeApp = fm.fileExists(atPath: "/Applications/Xcode.app")
        if xcodeRes.success && !xcodeRes.output.isEmpty {
            let versionRes = runQuickCommand("/usr/bin/xcodebuild", args: ["-version"])
            let firstLine = versionRes.output.components(separatedBy: .newlines).first ?? xcodeRes.output
            prereqs.xcode = DependencyStatus(id: "xcode", name: "Xcode & Command Line Tools", isAvailable: true, details: firstLine, recommendation: nil, installCommand: "xcode-select --install", repairCommand: "xcode-select --reset", uninstallCommand: nil, isProtected: true)
        } else if hasXcodeApp {
            prereqs.xcode = DependencyStatus(id: "xcode", name: "Xcode & Command Line Tools", isAvailable: false, details: "Xcode detected, CLT not linked", recommendation: "Run 'xcode-select --install' or switch to Xcode path", installCommand: "xcode-select --install", repairCommand: "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer", uninstallCommand: nil, isProtected: true)
        } else {
            prereqs.xcode = DependencyStatus(id: "xcode", name: "Xcode & Command Line Tools", isAvailable: false, details: "Not Installed", recommendation: "Install Apple Command Line Tools via 'xcode-select --install'", installCommand: "xcode-select --install", repairCommand: "xcode-select --reset", uninstallCommand: nil, isProtected: true)
        }
        
        func findBinary(_ name: String) -> String? {
            if let bundled = BundledTools.tool(name) {
                return bundled
            }
            let userHome = fm.homeDirectoryForCurrentUser.path
            let search = [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "/usr/local/share/dotnet/\(name)",
                "\(userHome)/.dotnet/\(name)",
                "/usr/bin/\(name)"
            ]
            for path in search where fm.fileExists(atPath: path) {
                return path
            }
            return nil
        }
        
        // 2. Check Homebrew presence (final availability is resolved after checking whether any brew-managed tool is missing)
        let isBundled = BundledTools.isBundledPythonAvailable
        let detectedBrewPath = findBinary("brew")
        let isHomebrewInstalled = detectedBrewPath != nil
        func brewMissingRec(for toolName: String) -> String {
            isHomebrewInstalled ? "Install \(toolName) via Homebrew" : "Install Homebrew first to install \(toolName)"
        }
        
        // 3. Git Version Control
        if let gitPath = findBinary("git") {
            let gitVer = runQuickCommand(gitPath, args: ["--version"])
            prereqs.git = DependencyStatus(id: "git", name: "Git Version Control", isAvailable: true, details: "\(gitVer.output) (\(gitPath))", recommendation: nil, installCommand: "brew install git", repairCommand: "brew reinstall git", uninstallCommand: nil, isProtected: true)
        } else {
            let rec = isHomebrewInstalled ? "Install Git via Homebrew or Xcode CLT" : "Install Homebrew first to install Git"
            prereqs.git = DependencyStatus(id: "git", name: "Git Version Control", isAvailable: false, details: "Not Found", recommendation: rec, installCommand: "brew install git", repairCommand: "brew reinstall git", uninstallCommand: nil, isProtected: true)
        }
        
        // 4. Python 3 Runtime Detection (Bundled or System Stable 3.12-3.14)
        let pyInfo = SystemDetector.findBestPython()
        let chosenPyPath = pyInfo.path
        let chosenPyVersion = pyInfo.version
        
        let pipInstallCmd: String
        let pipRepairCmd: String
        let pipUninstallCmd: String
        
        if let pyPath = chosenPyPath {
            pipInstallCmd = "if \"\(pyPath)\" -m pip install --help 2>&1 | grep -q -- '--break-system-packages'; then \"\(pyPath)\" -m pip install --break-system-packages lz4 capstone fonttools zbic && (\"\(pyPath)\" -m pip install --break-system-packages nsz 2>/dev/null || true); else \"\(pyPath)\" -m pip install lz4 capstone fonttools zbic && (\"\(pyPath)\" -m pip install nsz 2>/dev/null || true); fi"
            pipRepairCmd = "if \"\(pyPath)\" -m pip install --help 2>&1 | grep -q -- '--break-system-packages'; then \"\(pyPath)\" -m pip install --force-reinstall --break-system-packages lz4 capstone fonttools zbic && (\"\(pyPath)\" -m pip install --force-reinstall --break-system-packages nsz 2>/dev/null || true); else \"\(pyPath)\" -m pip install --force-reinstall lz4 capstone fonttools zbic && (\"\(pyPath)\" -m pip install --force-reinstall nsz 2>/dev/null || true); fi"
            pipUninstallCmd = "if \"\(pyPath)\" -m pip uninstall --help 2>&1 | grep -q -- '--break-system-packages'; then \"\(pyPath)\" -m pip uninstall -y --break-system-packages lz4 capstone fonttools zbic nsz 2>/dev/null || true; else \"\(pyPath)\" -m pip uninstall -y lz4 capstone fonttools zbic nsz 2>/dev/null || true; fi"
        } else {
            pipInstallCmd = "brew install python@3.13"
            pipRepairCmd = "brew reinstall python@3.13"
            pipUninstallCmd = ""
        }

        if pyInfo.isBundled, let pyPath = chosenPyPath {
            prereqs.python = DependencyStatus(id: "python", name: "Python 3", isAvailable: true, details: "\(chosenPyVersion) (Isolated Standalone)", recommendation: nil, installCommand: "", repairCommand: "", uninstallCommand: nil, isProtected: true)
            let pyCheck = runQuickCommand(pyPath, args: ["-B", "-c", "import lz4, capstone, fontTools, zbic; print('OK')"])
            let nszCheck = runQuickCommand(pyPath, args: ["-B", "-c", "import nsz; print('OK')"])
            let hasPackages = pyCheck.success && pyCheck.output.contains("OK")
            let nszNote = nszCheck.success ? " + nsz" : ""
            prereqs.pythonPackages = DependencyStatus(
                id: "python_packages", name: "Python Modules", isAvailable: hasPackages,
                details: hasPackages ? "lz4, capstone, fonttools, zbic\(nszNote) (Pre-bundled)" : "Bundled packages need verification",
                recommendation: nil, installCommand: pipInstallCmd, repairCommand: pipRepairCmd, uninstallCommand: pipUninstallCmd, isProtected: true
            )
        } else if pyInfo.isSufficient, let pyPath = chosenPyPath {
            prereqs.python = DependencyStatus(id: "python", name: "Python 3", isAvailable: true, details: "\(chosenPyVersion) (\(pyPath))", recommendation: nil, installCommand: "brew install python@3.13", repairCommand: "brew reinstall python@3.13", uninstallCommand: nil, isProtected: false)
            let pyCheck = runQuickCommand(pyPath, args: ["-B", "-c", "import lz4, capstone, fontTools, zbic; print('OK')"])
            if pyCheck.success && pyCheck.output.contains("OK") {
                let nszCheck = runQuickCommand(pyPath, args: ["-B", "-c", "import nsz; print('OK')"])
                let nszNote = nszCheck.success ? " + nsz" : " (nsz optional)"
                prereqs.pythonPackages = DependencyStatus(
                    id: "python_packages", name: "Python Modules", isAvailable: true,
                    details: "lz4, capstone, fonttools, zbic\(nszNote) installed",
                    recommendation: nszCheck.success ? nil : "Note: Compressed .nsz/.xcz files require standalone nsz or Python <= 3.14",
                    installCommand: pipInstallCmd, repairCommand: pipRepairCmd, uninstallCommand: pipUninstallCmd, isProtected: false
                )
            } else {
                prereqs.pythonPackages = DependencyStatus(
                    id: "python_packages", name: "Python Modules", isAvailable: false,
                    details: "Missing required packages for \(chosenPyVersion)", recommendation: "Install packages via pip",
                    installCommand: pipInstallCmd, repairCommand: pipRepairCmd, uninstallCommand: pipUninstallCmd, isProtected: false
                )
            }
        } else if pyInfo.isExperimental, let pyPath = chosenPyPath {
            let rec = isHomebrewInstalled
                ? "Python 3.15+ cannot compile native extensions (lz4). Click Repair to install stable Python 3.13 via Homebrew."
                : "Install Homebrew first, then install stable Python 3.13 via 'brew install python@3.13'."
            prereqs.python = DependencyStatus(
                id: "python", name: "Python 3", isAvailable: false,
                details: "\(chosenPyVersion) (\(pyPath)) — Incompatible with C-extensions (lz4)", recommendation: rec,
                installCommand: "brew install python@3.13", repairCommand: "brew reinstall python@3.13", uninstallCommand: nil, isProtected: false
            )
            prereqs.pythonPackages = DependencyStatus(
                id: "python_packages", name: "Python Modules", isAvailable: false,
                details: "Cannot build packages on Python 3.15+", recommendation: "Install Python 3.13: click Repair on Python 3 above",
                installCommand: "brew install python@3.13", repairCommand: "brew reinstall python@3.13", uninstallCommand: nil, isProtected: false
            )
        } else if let pyPath = chosenPyPath {
            let rec = isHomebrewInstalled ? "Python 3.12+ is required. Click Install to install modern Python via Homebrew." : "Install Homebrew first, then install Python 3.12+."
            prereqs.python = DependencyStatus(
                id: "python", name: "Python 3", isAvailable: false,
                details: "\(chosenPyVersion) (\(pyPath)) - Python 3.12-3.14 required", recommendation: rec,
                installCommand: "brew install python@3.13", repairCommand: "brew reinstall python@3.13", uninstallCommand: nil, isProtected: false
            )
            prereqs.pythonPackages = DependencyStatus(
                id: "python_packages", name: "Python Modules", isAvailable: false,
                details: "Requires Python 3.12-3.14", recommendation: isHomebrewInstalled ? "Install Python 3.13 first via Homebrew" : "Install Homebrew first",
                installCommand: "brew install python@3.13", repairCommand: "brew reinstall python@3.13", uninstallCommand: nil, isProtected: false
            )
        } else {
            let rec = isHomebrewInstalled ? "Install Python 3.13 via Homebrew" : "Install Homebrew first to install Python 3"
            prereqs.python = DependencyStatus(
                id: "python", name: "Python 3", isAvailable: false, details: "Not Found", recommendation: rec,
                installCommand: "brew install python@3.13", repairCommand: "brew reinstall python@3.13", uninstallCommand: nil, isProtected: false
            )
            prereqs.pythonPackages = DependencyStatus(
                id: "python_packages", name: "Python Modules", isAvailable: false,
                details: "Python 3 Not Found", recommendation: isHomebrewInstalled ? "Install Python 3 first via Homebrew" : "Install Homebrew first",
                installCommand: "brew install python@3.13", repairCommand: "brew reinstall python@3.13", uninstallCommand: nil, isProtected: false
            )
        }
        
        // 5. libimobiledevice (afcclient & idevice_id for USB streaming to iOS/iPadOS)
        func probeLibimobiledeviceBinary(_ path: String) -> (loaded: Bool, versionLine: String?) {
            let res = BoundedProcess.run(path, ["--version"], timeout: 2.5)
            guard !res.timedOut,
                  let status = res.status,
                  status >= 0 && status < 128,
                  !res.output.contains("Library not loaded"),
                  !res.output.contains("dyld[") else {
                return (false, nil)
            }
            let firstLine: String? = (status == 0)
                ? res.output
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                : nil
            return (true, firstLine)
        }

        let afcPath = findBinary("afcclient")
        let ideviceIdPath = findBinary("idevice_id")
        if let afc = afcPath, let idev = ideviceIdPath {
            let afcProbe = probeLibimobiledeviceBinary(afc)
            let idevProbe = probeLibimobiledeviceBinary(idev)
            if afcProbe.loaded && idevProbe.loaded {
                let verLabel = afcProbe.versionLine ?? idevProbe.versionLine ?? "Installed"
                prereqs.libimobiledevice = DependencyStatus(
                    id: "libimobiledevice",
                    name: "libimobiledevice (afcclient)",
                    isAvailable: true,
                    details: "\(verLabel) (\(afc))",
                    recommendation: nil,
                    installCommand: "brew install libimobiledevice",
                    repairCommand: "brew reinstall libimobiledevice",
                    uninstallCommand: "brew uninstall libimobiledevice",
                    isProtected: false
                )
            } else {
                prereqs.libimobiledevice = DependencyStatus(
                    id: "libimobiledevice",
                    name: "libimobiledevice (afcclient)",
                    isAvailable: false,
                    details: "Broken runtime libraries (dyld)",
                    recommendation: isHomebrewInstalled ? "Click Repair to reinstall libimobiledevice and its dependencies" : brewMissingRec(for: "libimobiledevice"),
                    installCommand: "brew install libimobiledevice",
                    repairCommand: "brew reinstall libimobiledevice",
                    uninstallCommand: "brew uninstall libimobiledevice",
                    isProtected: false
                )
            }
        } else {
            let partial = afcPath != nil ? "afcclient found, idevice_id missing" : (ideviceIdPath != nil ? "idevice_id found, afcclient missing" : "Not Found")
            prereqs.libimobiledevice = DependencyStatus(
                id: "libimobiledevice",
                name: "libimobiledevice (afcclient)",
                isAvailable: false,
                details: partial,
                recommendation: isHomebrewInstalled
                    ? "Required for fast USB streaming of large games (>4 GB) to iPhone/iPad"
                    : brewMissingRec(for: "libimobiledevice"),
                installCommand: "brew install libimobiledevice",
                repairCommand: "brew reinstall libimobiledevice",
                uninstallCommand: "brew uninstall libimobiledevice",
                isProtected: false
            )
        }

        // 6. .NET SDK
        if let dotnetPath = findBinary("dotnet") {
            let dotnetVer = runQuickCommand(dotnetPath, args: ["--version"])
            prereqs.dotnet = DependencyStatus(id: "dotnet", name: ".NET SDK", isAvailable: true, details: "v\(dotnetVer.output) (\(dotnetPath))", recommendation: nil, installCommand: "brew install --cask dotnet-sdk", repairCommand: "brew reinstall --cask dotnet-sdk", uninstallCommand: "brew uninstall --cask dotnet-sdk", isProtected: false)
        } else {
            let rec = isHomebrewInstalled ? "Install .NET SDK via Homebrew" : "Install .NET 10 SDK via Microsoft installer"
            let cmd = isHomebrewInstalled ? "brew install --cask dotnet-sdk" : "curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0"
            prereqs.dotnet = DependencyStatus(id: "dotnet", name: ".NET SDK", isAvailable: false, details: "Not Found", recommendation: rec, installCommand: cmd, repairCommand: cmd, uninstallCommand: nil, isProtected: false)
        }
        
        // 7. XcodeGen
        if let xcodegenPath = findBinary("xcodegen") {
            let xcodegenVer = runQuickCommand(xcodegenPath, args: ["--version"])
            prereqs.xcodegen = DependencyStatus(id: "xcodegen", name: "XcodeGen", isAvailable: true, details: xcodegenVer.output, recommendation: nil, installCommand: "brew install xcodegen", repairCommand: "brew reinstall xcodegen", uninstallCommand: "brew uninstall xcodegen", isProtected: false)
        } else {
            prereqs.xcodegen = DependencyStatus(id: "xcodegen", name: "XcodeGen", isAvailable: false, details: "Not Found", recommendation: brewMissingRec(for: "XcodeGen"), installCommand: "brew install xcodegen", repairCommand: "brew reinstall xcodegen", uninstallCommand: "brew uninstall xcodegen", isProtected: false)
        }
        
        // 8. zstd
        if let zstdPath = findBinary("zstd") {
            prereqs.zstd = DependencyStatus(id: "zstd", name: "zstd", isAvailable: true, details: "Installed (\(zstdPath))", recommendation: nil, installCommand: "brew install zstd", repairCommand: "brew reinstall zstd", uninstallCommand: "brew uninstall zstd", isProtected: false)
        } else {
            prereqs.zstd = DependencyStatus(id: "zstd", name: "zstd", isAvailable: false, details: "Not Found", recommendation: brewMissingRec(for: "zstd"), installCommand: "brew install zstd", repairCommand: "brew reinstall zstd", uninstallCommand: "brew uninstall zstd", isProtected: false)
        }
        
        // 9. spirv-cross
        if let spirvPath = findBinary("spirv-cross") {
            prereqs.spirvCross = DependencyStatus(id: "spirv_cross", name: "spirv-cross", isAvailable: true, details: "Installed (\(spirvPath))", recommendation: nil, installCommand: "brew install spirv-cross", repairCommand: "brew reinstall spirv-cross", uninstallCommand: "brew uninstall spirv-cross", isProtected: false)
        } else {
            prereqs.spirvCross = DependencyStatus(id: "spirv_cross", name: "spirv-cross", isAvailable: false, details: "Not Found", recommendation: brewMissingRec(for: "spirv-cross"), installCommand: "brew install spirv-cross", repairCommand: "brew reinstall spirv-cross", uninstallCommand: "brew uninstall spirv-cross", isProtected: false)
        }
        
        // 10. glslangValidator
        if let glslangPath = findBinary("glslangValidator") {
            prereqs.glslang = DependencyStatus(id: "glslang", name: "glslang", isAvailable: true, details: "Installed (\(glslangPath))", recommendation: nil, installCommand: "brew install glslang", repairCommand: "brew reinstall glslang", uninstallCommand: "brew uninstall glslang", isProtected: false, downloadSizeBadge: "~25 MB", installedSizeBadge: "~60 MB", category: .core)
        } else {
            prereqs.glslang = DependencyStatus(id: "glslang", name: "glslang", isAvailable: false, details: "Not Found", recommendation: brewMissingRec(for: "glslang"), installCommand: "brew install glslang", repairCommand: "brew reinstall glslang", uninstallCommand: "brew uninstall glslang", isProtected: false, downloadSizeBadge: "~25 MB", installedSizeBadge: "~60 MB", category: .core)
        }

        // 11. Android Platform-Tools (adb)
        let userHome = fm.homeDirectoryForCurrentUser.path
        let adbSearchPaths = [
            findBinary("adb"),
            "\(userHome)/Library/Application Support/nx2android/toolchains/platform-tools/adb",
            "\(userHome)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb"
        ].compactMap { $0 }

        var detectedAdb: String? = nil
        for path in adbSearchPaths where fm.fileExists(atPath: path) {
            detectedAdb = path
            break
        }

        if let adbPath = detectedAdb {
            let adbVer = runQuickCommand(adbPath, args: ["version"])
            let firstLine = adbVer.output.components(separatedBy: .newlines).first ?? "Installed"
            prereqs.androidAdb = DependencyStatus(
                id: "android_adb",
                name: "Android Platform-Tools (adb)",
                isAvailable: true,
                details: "\(firstLine) (\(adbPath))",
                recommendation: nil,
                installCommand: prereqs.androidAdb.installCommand,
                repairCommand: prereqs.androidAdb.repairCommand,
                uninstallCommand: prereqs.androidAdb.uninstallCommand,
                isProtected: false,
                downloadSizeBadge: "~15 MB",
                installedSizeBadge: "~50 MB",
                category: .android
            )
        } else {
            prereqs.androidAdb = DependencyStatus(
                id: "android_adb",
                name: "Android Platform-Tools (adb)",
                isAvailable: false,
                details: "Not Found",
                recommendation: isHomebrewInstalled ? "Install via Homebrew or click Install (~15 MB)" : "Click Install to download (~15 MB)",
                installCommand: prereqs.androidAdb.installCommand,
                repairCommand: prereqs.androidAdb.repairCommand,
                uninstallCommand: prereqs.androidAdb.uninstallCommand,
                isProtected: false,
                downloadSizeBadge: "~15 MB",
                installedSizeBadge: "~50 MB",
                category: .android
            )
        }

        // 12. Android NDK (r27c)
        let envNdk = ProcessInfo.processInfo.environment["ANDROID_NDK_HOME"]
        let ndkSearchCandidates = [
            envNdk,
            "\(userHome)/Library/Application Support/nx2android/toolchains/android-ndk-r27c",
            "\(userHome)/Library/Android/sdk/ndk/27.2.12479018",
            "\(userHome)/Library/Android/sdk/ndk/27.1.12297006",
            "\(userHome)/Library/Android/sdk/ndk/27.0.12077973"
        ].compactMap { $0 }

        var detectedNdkPath: String? = nil
        var detectedNdkVer: String? = nil

        func readNdkRevision(at dir: String) -> String? {
            let props = URL(fileURLWithPath: dir).appendingPathComponent("source.properties").path
            guard fm.fileExists(atPath: props),
                  let content = try? String(contentsOfFile: props, encoding: .utf8) else { return nil }
            for line in content.components(separatedBy: .newlines) {
                if line.starts(with: "Pkg.Revision") {
                    let parts = line.components(separatedBy: "=")
                    if parts.count > 1 {
                        return parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            return nil
        }

        for path in ndkSearchCandidates where fm.fileExists(atPath: path) {
            if let rev = readNdkRevision(at: path) {
                detectedNdkPath = path
                detectedNdkVer = rev
                break
            }
        }

        if let ndkPath = detectedNdkPath, let rev = detectedNdkVer {
            let isR27 = rev.starts(with: "27.")
            prereqs.androidNdk = DependencyStatus(
                id: "android_ndk",
                name: "Android NDK (r27c)",
                isAvailable: isR27,
                details: isR27 ? "v\(rev) (\(ndkPath))" : "v\(rev) (Tested with r27c / 27.x)",
                recommendation: isR27 ? nil : "Host is built and qualified for NDK r27c. Other versions may produce build errors.",
                installCommand: prereqs.androidNdk.installCommand,
                repairCommand: prereqs.androidNdk.repairCommand,
                uninstallCommand: prereqs.androidNdk.uninstallCommand,
                isProtected: false,
                downloadSizeBadge: "~1.1 GB",
                installedSizeBadge: "~2.6 GB",
                category: .android
            )
        } else {
            prereqs.androidNdk = DependencyStatus(
                id: "android_ndk",
                name: "Android NDK (r27c)",
                isAvailable: false,
                details: "Not Found",
                recommendation: "Required only for compiling Android APKs (~1.1 GB download / ~2.6 GB disk).",
                installCommand: prereqs.androidNdk.installCommand,
                repairCommand: prereqs.androidNdk.repairCommand,
                uninstallCommand: prereqs.androidNdk.uninstallCommand,
                isProtected: false,
                downloadSizeBadge: "~1.1 GB",
                installedSizeBadge: "~2.6 GB",
                category: .android
            )
        }

        // Finalize Homebrew status: only optional if brew-managed tools are all already satisfied
        let allBrewManagedReady = prereqs.git.isAvailable &&
            prereqs.libimobiledevice.isAvailable &&
            prereqs.dotnet.isAvailable &&
            prereqs.xcodegen.isAvailable &&
            prereqs.zstd.isAvailable &&
            prereqs.spirvCross.isAvailable &&
            prereqs.glslang.isAvailable
        if let brewPath = detectedBrewPath {
            let brewVer = runQuickCommand(brewPath, args: ["--version"])
            let firstLine = brewVer.output.components(separatedBy: .newlines).first ?? brewVer.output
            prereqs.homebrew = DependencyStatus(
                id: "homebrew",
                name: "Homebrew Package Manager",
                isAvailable: true,
                details: "\(firstLine) (\(brewPath))",
                recommendation: nil,
                installCommand: prereqs.homebrew.installCommand,
                repairCommand: "brew update",
                uninstallCommand: nil,
                isProtected: true
            )
        } else {
            let optionalBecauseSatisfied = isBundled && allBrewManagedReady
            let rec: String? = optionalBecauseSatisfied
                ? nil
                : (prereqs.xcode.isAvailable
                    ? "Required first to install libimobiledevice and missing build tools."
                    : "Install Apple Command Line Tools first, then install Homebrew.")
            prereqs.homebrew = DependencyStatus(
                id: "homebrew",
                name: "Homebrew Package Manager",
                isAvailable: optionalBecauseSatisfied,
                details: optionalBecauseSatisfied ? "Not Installed (Optional — Required Tools Available)" : "Not Installed",
                recommendation: rec,
                installCommand: prereqs.homebrew.installCommand,
                repairCommand: "brew update",
                uninstallCommand: nil,
                isProtected: true
            )
        }
        
        return prereqs
    }
}
