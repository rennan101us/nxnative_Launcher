import Foundation

public enum DependencyPlatformCategory: String, CaseIterable, Codable, Sendable {
    case core = "core"
    case apple = "apple"
    case ios = "ios"
    case android = "android"
}

public struct DependencyStatus: Identifiable, Equatable {
    public let id: String
    public let name: String
    public var isAvailable: Bool
    public var details: String
    public var recommendation: String?
    public var installCommand: String?
    public var repairCommand: String?
    public var uninstallCommand: String?
    public var isProtected: Bool // Core system tools cannot be uninstalled
    public var isInstalling: Bool = false
    public var downloadSizeBadge: String?
    public var installedSizeBadge: String?
    public var category: DependencyPlatformCategory
    
    public init(
        id: String,
        name: String,
        isAvailable: Bool,
        details: String,
        recommendation: String? = nil,
        installCommand: String? = nil,
        repairCommand: String? = nil,
        uninstallCommand: String? = nil,
        isProtected: Bool = false,
        isInstalling: Bool = false,
        downloadSizeBadge: String? = nil,
        installedSizeBadge: String? = nil,
        category: DependencyPlatformCategory = .core
    ) {
        self.id = id
        self.name = name
        self.isAvailable = isAvailable
        self.details = details
        self.recommendation = recommendation
        self.installCommand = installCommand
        self.repairCommand = repairCommand
        self.uninstallCommand = uninstallCommand
        self.isProtected = isProtected
        self.isInstalling = isInstalling
        self.downloadSizeBadge = downloadSizeBadge
        self.installedSizeBadge = installedSizeBadge
        self.category = category
    }
}

public struct SystemPrerequisites {
    public var xcode: DependencyStatus = DependencyStatus(
        id: "xcode",
        name: "Xcode & Command Line Tools",
        isAvailable: false,
        details: "Checking...",
        recommendation: nil,
        installCommand: "xcode-select --install",
        repairCommand: "xcode-select --reset",
        uninstallCommand: nil,
        isProtected: true,
        downloadSizeBadge: "~1.5 GB",
        installedSizeBadge: "~3.5 GB",
        category: .apple
    )
    
    public var homebrew: DependencyStatus = DependencyStatus(
        id: "homebrew",
        name: "Homebrew Package Manager",
        isAvailable: false,
        details: "Checking...",
        recommendation: "Required to install and manage compilers, SDKs, and build tools",
        installCommand: "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\" && (if [ -x /opt/homebrew/bin/brew ]; then eval \"$(/opt/homebrew/bin/brew shellenv)\"; grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval \"$(/opt/homebrew/bin/brew shellenv)\"' >> ~/.zprofile; elif [ -x /usr/local/bin/brew ]; then eval \"$(/usr/local/bin/brew shellenv)\"; grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval \"$(/usr/local/bin/brew shellenv)\"' >> ~/.zprofile; fi)",
        repairCommand: "brew update",
        uninstallCommand: nil,
        isProtected: true,
        downloadSizeBadge: "~50 MB",
        installedSizeBadge: "~120 MB",
        category: .core
    )
    
    public var git: DependencyStatus = DependencyStatus(
        id: "git",
        name: "Git Version Control",
        isAvailable: false,
        details: "Checking...",
        recommendation: nil,
        installCommand: "brew install git",
        repairCommand: "brew reinstall git",
        uninstallCommand: nil,
        isProtected: true,
        downloadSizeBadge: "~60 MB",
        installedSizeBadge: "~110 MB",
        category: .core
    )
    
    public var python: DependencyStatus = DependencyStatus(
        id: "python",
        name: "Python 3",
        isAvailable: false,
        details: "Checking...",
        recommendation: nil,
        installCommand: "brew install python@3.13",
        repairCommand: "brew reinstall python@3.13",
        uninstallCommand: nil,
        isProtected: false,
        downloadSizeBadge: "~85 MB",
        installedSizeBadge: "~160 MB",
        category: .core
    )
    
    public var dotnet: DependencyStatus = DependencyStatus(
        id: "dotnet",
        name: ".NET SDK",
        isAvailable: false,
        details: "Checking...",
        recommendation: nil,
        installCommand: "brew install --cask dotnet-sdk",
        repairCommand: "brew reinstall --cask dotnet-sdk",
        uninstallCommand: "brew uninstall --cask dotnet-sdk",
        isProtected: false,
        downloadSizeBadge: "~220 MB",
        installedSizeBadge: "~900 MB",
        category: .core
    )
    
    public var xcodegen: DependencyStatus = DependencyStatus(
        id: "xcodegen",
        name: "XcodeGen",
        isAvailable: false,
        details: "Checking...",
        recommendation: nil,
        installCommand: "brew install xcodegen",
        repairCommand: "brew reinstall xcodegen",
        uninstallCommand: "brew uninstall xcodegen",
        isProtected: false,
        downloadSizeBadge: "~15 MB",
        installedSizeBadge: "~35 MB",
        category: .apple
    )
    
    public var zstd: DependencyStatus = DependencyStatus(
        id: "zstd",
        name: "zstd",
        isAvailable: false,
        details: "Checking...",
        recommendation: nil,
        installCommand: "brew install zstd",
        repairCommand: "brew reinstall zstd",
        uninstallCommand: "brew uninstall zstd",
        isProtected: false,
        downloadSizeBadge: "~5 MB",
        installedSizeBadge: "~12 MB",
        category: .core
    )
    
    public var spirvCross: DependencyStatus = DependencyStatus(
        id: "spirv_cross",
        name: "spirv-cross",
        isAvailable: false,
        details: "Checking...",
        recommendation: nil,
        installCommand: "brew install spirv-cross",
        repairCommand: "brew reinstall spirv-cross",
        uninstallCommand: "brew uninstall spirv-cross",
        isProtected: false,
        downloadSizeBadge: "~10 MB",
        installedSizeBadge: "~25 MB",
        category: .core
    )
    
    public var glslang: DependencyStatus = DependencyStatus(
        id: "glslang",
        name: "glslang",
        isAvailable: false,
        details: "Checking...",
        recommendation: nil,
        installCommand: "brew install glslang",
        repairCommand: "brew reinstall glslang",
        uninstallCommand: "brew uninstall glslang",
        isProtected: false,
        downloadSizeBadge: "~25 MB",
        installedSizeBadge: "~60 MB",
        category: .core
    )
    
    public var pythonPackages: DependencyStatus = DependencyStatus(
        id: "python_packages",
        name: "Python Modules",
        isAvailable: false,
        details: "Checking...",
        recommendation: nil,
        installCommand: "PY_BIN=\"\"; for c in /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13 /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3 /usr/local/bin/python3 $(which python3); do if [ -x \"$c\" ]; then PY_BIN=\"$c\"; break; fi; done; if [ -n \"$PY_BIN\" ]; then if \"$PY_BIN\" -m pip install --help 2>&1 | grep -q -- '--break-system-packages'; then \"$PY_BIN\" -m pip install --break-system-packages lz4 capstone fonttools zbic && (\"$PY_BIN\" -m pip install --break-system-packages nsz 2>/dev/null || true); else \"$PY_BIN\" -m pip install lz4 capstone fonttools zbic && (\"$PY_BIN\" -m pip install nsz 2>/dev/null || true); fi; fi",
        repairCommand: "PY_BIN=\"\"; for c in /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13 /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3 /usr/local/bin/python3 $(which python3); do if [ -x \"$c\" ]; then PY_BIN=\"$c\"; break; fi; done; if [ -n \"$PY_BIN\" ]; then if \"$PY_BIN\" -m pip install --help 2>&1 | grep -q -- '--break-system-packages'; then \"$PY_BIN\" -m pip install --force-reinstall --break-system-packages lz4 capstone fonttools zbic && (\"$PY_BIN\" -m pip install --force-reinstall --break-system-packages nsz 2>/dev/null || true); else \"$PY_BIN\" -m pip install --force-reinstall lz4 capstone fonttools zbic && (\"$PY_BIN\" -m pip install --force-reinstall nsz 2>/dev/null || true); fi; fi",
        uninstallCommand: "PY_BIN=\"\"; for c in /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13 /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3 /usr/local/bin/python3 $(which python3); do if [ -x \"$c\" ]; then PY_BIN=\"$c\"; break; fi; done; if [ -n \"$PY_BIN\" ]; then if \"$PY_BIN\" -m pip uninstall --help 2>&1 | grep -q -- '--break-system-packages'; then \"$PY_BIN\" -m pip uninstall -y --break-system-packages lz4 capstone fonttools zbic nsz 2>/dev/null || true; else \"$PY_BIN\" -m pip uninstall -y lz4 capstone fonttools zbic nsz 2>/dev/null || true; fi; fi",
        isProtected: false,
        downloadSizeBadge: "~45 MB",
        installedSizeBadge: "~95 MB",
        category: .core
    )

    public var libimobiledevice: DependencyStatus = DependencyStatus(
        id: "libimobiledevice",
        name: "libimobiledevice (afcclient)",
        isAvailable: false,
        details: "Checking...",
        recommendation: nil,
        installCommand: "brew install libimobiledevice",
        repairCommand: "brew reinstall libimobiledevice",
        uninstallCommand: "brew uninstall libimobiledevice",
        isProtected: false,
        downloadSizeBadge: "~20 MB",
        installedSizeBadge: "~45 MB",
        category: .ios
    )

    public var androidNdk: DependencyStatus = DependencyStatus(
        id: "android_ndk",
        name: "Android NDK (r27c)",
        isAvailable: false,
        details: "Checking...",
        recommendation: "Required to compile ARM64/Vulkan native compatibility layer for Android",
        installCommand: "mkdir -p \"$HOME/Library/Application Support/nx2android/toolchains\" && curl -fsSL https://dl.google.com/android/repository/android-ndk-r27c-darwin.zip -o /tmp/android-ndk-r27c.zip && unzip -qo /tmp/android-ndk-r27c.zip -d \"$HOME/Library/Application Support/nx2android/toolchains\" && rm -f /tmp/android-ndk-r27c.zip",
        repairCommand: "rm -rf \"$HOME/Library/Application Support/nx2android/toolchains/android-ndk-r27c\" && mkdir -p \"$HOME/Library/Application Support/nx2android/toolchains\" && curl -fsSL https://dl.google.com/android/repository/android-ndk-r27c-darwin.zip -o /tmp/android-ndk-r27c.zip && unzip -qo /tmp/android-ndk-r27c.zip -d \"$HOME/Library/Application Support/nx2android/toolchains\" && rm -f /tmp/android-ndk-r27c.zip",
        uninstallCommand: "rm -rf \"$HOME/Library/Application Support/nx2android/toolchains/android-ndk-r27c\"",
        isProtected: false,
        downloadSizeBadge: "~1.1 GB",
        installedSizeBadge: "~2.6 GB",
        category: .android
    )

    public var androidAdb: DependencyStatus = DependencyStatus(
        id: "android_adb",
        name: "Android Platform-Tools (adb)",
        isAvailable: false,
        details: "Checking...",
        recommendation: "Required for USB communication, APK installation, and RomFS data push",
        installCommand: "if which brew >/dev/null 2>&1; then brew install --cask android-platform-tools; else mkdir -p \"$HOME/Library/Application Support/nx2android/toolchains\" && curl -fsSL https://dl.google.com/android/repository/platform-tools-latest-darwin.zip -o /tmp/platform-tools.zip && unzip -qo /tmp/platform-tools.zip -d \"$HOME/Library/Application Support/nx2android/toolchains\" && rm -f /tmp/platform-tools.zip; fi",
        repairCommand: "if which brew >/dev/null 2>&1; then brew reinstall --cask android-platform-tools; else rm -rf \"$HOME/Library/Application Support/nx2android/toolchains/platform-tools\" && curl -fsSL https://dl.google.com/android/repository/platform-tools-latest-darwin.zip -o /tmp/platform-tools.zip && unzip -qo /tmp/platform-tools.zip -d \"$HOME/Library/Application Support/nx2android/toolchains\" && rm -f /tmp/platform-tools.zip; fi",
        uninstallCommand: "brew uninstall --cask android-platform-tools 2>/dev/null || rm -rf \"$HOME/Library/Application Support/nx2android/toolchains/platform-tools\"",
        isProtected: false,
        downloadSizeBadge: "~15 MB",
        installedSizeBadge: "~50 MB",
        category: .android
    )
    
    /// Canonical installation order so foundational managers precede the formulae they install.
    public static let canonicalDependencyOrder: [String] = [
        "xcode",
        "homebrew",
        "git",
        "python",
        "python_packages",
        "libimobiledevice",
        "android_adb",
        "dotnet",
        "xcodegen",
        "zstd",
        "spirv_cross",
        "glslang",
        "android_ndk"
    ]

    public static func ordered(_ dependencies: [DependencyStatus]) -> [DependencyStatus] {
        let rankById = Dictionary(uniqueKeysWithValues: canonicalDependencyOrder.enumerated().map { ($0.element, $0.offset) })
        return dependencies.enumerated().sorted { lhs, rhs in
            let r1 = rankById[lhs.element.id] ?? Int.max
            let r2 = rankById[rhs.element.id] ?? Int.max
            return r1 != r2 ? r1 < r2 : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Check if all dependencies required for the default Mac experience are satisfied.
    public var allSatisfied: Bool {
        let coreReady = xcode.isAvailable &&
            git.isAvailable &&
            python.isAvailable &&
            pythonPackages.isAvailable &&
            dotnet.isAvailable &&
            xcodegen.isAvailable &&
            zstd.isAvailable &&
            spirvCross.isAvailable &&
            glslang.isAvailable
        return coreReady && homebrew.isAvailable
    }
    
    public var missingList: [DependencyStatus] {
        Self.ordered(list.filter { !$0.isAvailable })
    }
    
    public var list: [DependencyStatus] {
        [xcode, homebrew, git, python, pythonPackages, libimobiledevice, androidAdb, dotnet, xcodegen, zstd, spirvCross, glslang, androidNdk]
    }

    /// Dependencies filtered by the user's selected target platforms.
    public func list(for platforms: Set<TargetPlatform>) -> [DependencyStatus] {
        let effectivePlatforms = platforms.isEmpty ? Set([TargetPlatform.macApp]) : platforms
        return list.filter { item in
            switch item.category {
            case .core:
                return true
            case .apple:
                return effectivePlatforms.contains(.macApp) || effectivePlatforms.contains(.ios)
            case .ios:
                return effectivePlatforms.contains(.ios)
            case .android:
                return effectivePlatforms.contains(.android)
            }
        }
    }

    public func missingList(for platforms: Set<TargetPlatform>) -> [DependencyStatus] {
        Self.ordered(list(for: platforms).filter { !$0.isAvailable })
    }

    public func allSatisfied(for platforms: Set<TargetPlatform>) -> Bool {
        missingList(for: platforms).isEmpty
    }
}
