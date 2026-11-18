import AppKit
import Foundation

public struct GameRuntimeConfig: Codable, Equatable {
    public var enable60FPS: Bool
    public var enableMetalHUD: Bool
    public var isDockedMode: Bool // true = Docked (1080p), false = Handheld (720p)
    public var renderScale: Double // 0.5 to 1.0
    public var enableMetalFXUpscale: Bool // true = MetalFX, false = off
    public var enableGameMode: Bool // true = Full Screen (macOS Game Mode ON), false = Windowed
    public var enableGamepadProfile: Bool // true = Apply custom gamepad profile remapping, false = Native 1:1 controller input
    public var controllerProfileId: String? // nil = Global Active Profile; UUID string = Pinned Profile
    public var playerProfileIds: [String: String]? // [PlayerSlot: ProfileUUID] (ex: "0": "...", "1": "...")
    public var gameLanguage: String? // nil = Game's default DMLanguage; non-nil = DM_LANG override
    
    // Zelda OoT Enhanced Mode optimizations
    public var ootUpscalerMode: String // "off" = Native Direct (Bypass NDSR + optional CAS), "metalfx" = MetalFX, "game" = Original NDSR
    public var ootSharpen: Double // 0.0 to 1.0 (default 0.25)
    public var ootFixedResolution: Bool // default true (lock internal render scale to 100% native, DM_DYNAMIC_RESOLUTION=0)
    public var ootFixedScale: Double // default 1.0
    public var ootGfxScaleTier: Int // 0 = Native 100%, 1 = Low-RAM (0.8x), 2 = Ultra Low-RAM (0.67x)
    public var ootMicrophone: Bool // default true (microphone audio support)
    public var oot16GBRamMode: Bool // auto-enabled on <= 16 GB RAM Macs (guarded DM_GUEST_FILE + DM_NVN_RT_LOSSY; always DM_TEX_RELEASE=0)
    public var ootResolutionPreset: String // "normal" (DM_RES_PRESET=0) or "potato" (DM_RES_PRESET=1)
    public var ootExperimentalFrameGen: Bool // default false (Stage-1 Frame Blend 120 Hz DM_FRAMEGEN)
    public var ootFrameGenMaxK: Int // 2 = fixed 2x cadence, 4 = adaptive 2x-4x cadence
    public var ootMotionBlur: Bool // default true (camera motion blur DM_OOT_MOTION_BLUR: 1 = original, 0 = disabled)

    public static let minTempBytesForGuestFile: Int64 = 12 * 1024 * 1024 * 1024 // 12 GB safety margin (engine requires >= 10 GB)

    public static var systemPhysicalRamGB: Int {
        return Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    public static var default16GBRamMode: Bool {
        return systemPhysicalRamGB <= 16
    }

    public static func availableTempDiskBytes() -> Int64 {
        let tempPath = NSTemporaryDirectory()
        let tempURL = URL(fileURLWithPath: tempPath, isDirectory: true)
        if let values = try? tempURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity, capacity > 0 {
            return Int64(capacity)
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: tempPath),
           let freeNum = attrs[.systemFreeSize] as? NSNumber {
            return freeNum.int64Value
        }
        return 0
    }

    public static var tempHasSpaceForGuestFile: Bool {
        return availableTempDiskBytes() >= minTempBytesForGuestFile
    }

    private static let suppressInputExportThreadKey = "nxnative.GameRuntimeConfig.suppressInputExport"

    public static var isInputProfileExportSuppressed: Bool {
        return (Thread.current.threadDictionary[suppressInputExportThreadKey] as? Bool) == true
    }

    @discardableResult
    public static func withSuppressedInputProfileExport<T>(_ body: () -> T) -> T {
        let dict = Thread.current.threadDictionary
        let previous = dict[suppressInputExportThreadKey]
        dict[suppressInputExportThreadKey] = true
        defer {
            if let previous {
                dict[suppressInputExportThreadKey] = previous
            } else {
                dict.removeObject(forKey: suppressInputExportThreadKey)
            }
        }
        return body()
    }

    private static func preservedMetalHUDState(for game: PortedGame, storageKey: String) -> Bool {
        let bundleId = game.bundleId ?? Bundle(url: game.url)?.bundleIdentifier
        if let bundleId, !bundleId.isEmpty,
           let suite = UserDefaults(suiteName: bundleId),
           let raw = suite.object(forKey: "launcher.DM_METAL_HUD") {
            if let str = raw as? String, str == "1" || str.lowercased() == "true" {
                return true
            }
            if let flag = raw as? Bool, flag {
                return true
            }
            if let str = raw as? String, str == "0" || str.lowercased() == "false" {
                // Only fall through if suite explicitly holds a default "0" while UserDefaults had true
                if let data = UserDefaults.standard.data(forKey: storageKey),
                   let prior = try? JSONDecoder().decode(GameRuntimeConfig.self, from: data),
                   prior.enableMetalHUD {
                    return true
                }
                return false
            }
        }
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let prior = try? JSONDecoder().decode(GameRuntimeConfig.self, from: data) {
            return prior.enableMetalHUD
        }
        let envUrl = game.url.appendingPathComponent("Contents/Resources/dm/env.txt")
        if let content = try? String(contentsOf: envUrl, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "DM_METAL_HUD=1" { return true }
                if trimmed == "DM_METAL_HUD=0" { return false }
            }
        }
        return false
    }
    
    public init(
        enable60FPS: Bool = true,
        enableMetalHUD: Bool = false,
        isDockedMode: Bool = true,
        renderScale: Double = 1.0,
        enableMetalFXUpscale: Bool = false,
        enableGameMode: Bool = true,
        enableGamepadProfile: Bool = true,
        controllerProfileId: String? = nil,
        playerProfileIds: [String: String]? = nil,
        gameLanguage: String? = nil,
        ootUpscalerMode: String = "off",
        ootSharpen: Double = 0.25,
        ootFixedResolution: Bool = true,
        ootFixedScale: Double = 1.0,
        ootGfxScaleTier: Int = 0,
        ootMicrophone: Bool = true,
        oot16GBRamMode: Bool = GameRuntimeConfig.default16GBRamMode,
        ootResolutionPreset: String = "normal",
        ootExperimentalFrameGen: Bool = false,
        ootFrameGenMaxK: Int = 4,
        ootMotionBlur: Bool = true
    ) {
        self.enable60FPS = enable60FPS
        self.enableMetalHUD = enableMetalHUD
        self.isDockedMode = isDockedMode
        self.renderScale = renderScale
        self.enableMetalFXUpscale = enableMetalFXUpscale
        self.enableGameMode = enableGameMode
        self.enableGamepadProfile = enableGamepadProfile
        self.controllerProfileId = controllerProfileId
        self.playerProfileIds = playerProfileIds
        self.gameLanguage = gameLanguage
        self.ootUpscalerMode = ootUpscalerMode
        self.ootSharpen = ootSharpen
        self.ootFixedResolution = ootFixedResolution
        self.ootFixedScale = ootFixedScale
        self.ootGfxScaleTier = ootGfxScaleTier
        self.ootMicrophone = ootMicrophone
        self.oot16GBRamMode = oot16GBRamMode
        self.ootResolutionPreset = ootResolutionPreset
        self.ootExperimentalFrameGen = ootExperimentalFrameGen
        self.ootFrameGenMaxK = ootFrameGenMaxK
        self.ootMotionBlur = ootMotionBlur
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enable60FPS = try container.decodeIfPresent(Bool.self, forKey: .enable60FPS) ?? true
        self.enableMetalHUD = try container.decodeIfPresent(Bool.self, forKey: .enableMetalHUD) ?? false
        self.isDockedMode = try container.decodeIfPresent(Bool.self, forKey: .isDockedMode) ?? true
        self.renderScale = try container.decodeIfPresent(Double.self, forKey: .renderScale) ?? 1.0
        self.enableMetalFXUpscale = try container.decodeIfPresent(Bool.self, forKey: .enableMetalFXUpscale) ?? false
        self.enableGameMode = try container.decodeIfPresent(Bool.self, forKey: .enableGameMode) ?? true
        self.enableGamepadProfile = try container.decodeIfPresent(Bool.self, forKey: .enableGamepadProfile) ?? true
        self.controllerProfileId = try container.decodeIfPresent(String.self, forKey: .controllerProfileId)
        self.playerProfileIds = try container.decodeIfPresent([String: String].self, forKey: .playerProfileIds)
        self.gameLanguage = try container.decodeIfPresent(String.self, forKey: .gameLanguage)
        self.ootUpscalerMode = try container.decodeIfPresent(String.self, forKey: .ootUpscalerMode) ?? "off"
        self.ootSharpen = try container.decodeIfPresent(Double.self, forKey: .ootSharpen) ?? 0.25
        self.ootFixedResolution = try container.decodeIfPresent(Bool.self, forKey: .ootFixedResolution) ?? true
        self.ootFixedScale = try container.decodeIfPresent(Double.self, forKey: .ootFixedScale) ?? 1.0
        self.ootGfxScaleTier = try container.decodeIfPresent(Int.self, forKey: .ootGfxScaleTier) ?? 0
        self.ootMicrophone = try container.decodeIfPresent(Bool.self, forKey: .ootMicrophone) ?? true
        self.oot16GBRamMode = try container.decodeIfPresent(Bool.self, forKey: .oot16GBRamMode) ?? Self.default16GBRamMode
        self.ootResolutionPreset = try container.decodeIfPresent(String.self, forKey: .ootResolutionPreset) ?? "normal"
        self.ootExperimentalFrameGen = try container.decodeIfPresent(Bool.self, forKey: .ootExperimentalFrameGen) ?? false
        self.ootFrameGenMaxK = try container.decodeIfPresent(Int.self, forKey: .ootFrameGenMaxK) ?? 4
        self.ootMotionBlur = try container.decodeIfPresent(Bool.self, forKey: .ootMotionBlur) ?? true
    }

    public static func languageDisplayInfo(for code: String) -> (flag: String, name: String, code: String) {
        switch code {
        case "en-US": return ("🇺🇸", "American English", "en-US")
        case "en-GB": return ("🇬🇧", "British English", "en-GB")
        case "ja": return ("🇯🇵", "Japanese (日本語)", "ja")
        case "fr": return ("🇫🇷", "French (Français)", "fr")
        case "de": return ("🇩🇪", "German (Deutsch)", "de")
        case "es-419": return ("🇲🇽", "Latin American Spanish (Español)", "es-419")
        case "es": return ("🇪🇸", "Spanish (Español)", "es")
        case "it": return ("🇮🇹", "Italian (Italiano)", "it")
        case "nl": return ("🇳🇱", "Dutch (Nederlands)", "nl")
        case "fr-CA": return ("🇨🇦", "Canadian French (Français)", "fr-CA")
        case "pt": return ("🇵🇹", "Portuguese (Português)", "pt")
        case "ru": return ("🇷🇺", "Russian (Русский)", "ru")
        case "ko": return ("🇰🇷", "Korean (한국어)", "ko")
        case "zh-Hant": return ("🇹🇼", "Traditional Chinese (繁體中文)", "zh-Hant")
        case "zh-Hans": return ("🇨🇳", "Simplified Chinese (简体中文)", "zh-Hans")
        case "pt-BR": return ("🇧🇷", "Brazilian Portuguese (Português)", "pt-BR")
        default: return ("🌐", code, code)
        }
    }

    public func matchesPerformanceSettings(of other: GameRuntimeConfig, isOot: Bool) -> Bool {
        if enable60FPS != other.enable60FPS { return false }
        if isDockedMode != other.isDockedMode { return false }
        if abs(renderScale - other.renderScale) > 0.01 { return false }
        if enableMetalFXUpscale != other.enableMetalFXUpscale { return false }
        if enableGameMode != other.enableGameMode { return false }
        if ootExperimentalFrameGen != other.ootExperimentalFrameGen { return false }
        if isOot {
            if ootUpscalerMode != other.ootUpscalerMode { return false }
            if abs(ootSharpen - other.ootSharpen) > 0.01 { return false }
            if ootFixedResolution != other.ootFixedResolution { return false }
            if ootGfxScaleTier != other.ootGfxScaleTier { return false }
            if oot16GBRamMode != other.oot16GBRamMode { return false }
            if ootResolutionPreset != other.ootResolutionPreset { return false }
            if ootMotionBlur != other.ootMotionBlur { return false }
        }
        return true
    }

    public mutating func applyPerformanceSettings(from other: GameRuntimeConfig, isOot: Bool) {
        self.enable60FPS = other.enable60FPS
        self.isDockedMode = other.isDockedMode
        self.renderScale = other.renderScale
        self.enableMetalFXUpscale = other.enableMetalFXUpscale
        self.enableGameMode = other.enableGameMode
        self.ootExperimentalFrameGen = other.ootExperimentalFrameGen
        self.ootFrameGenMaxK = other.ootFrameGenMaxK
        if isOot {
            self.ootUpscalerMode = other.ootUpscalerMode
            self.ootSharpen = other.ootSharpen
            self.ootFixedResolution = other.ootFixedResolution
            self.ootFixedScale = other.ootFixedScale
            self.ootGfxScaleTier = other.ootGfxScaleTier
            self.ootMicrophone = other.ootMicrophone
            self.oot16GBRamMode = other.oot16GBRamMode
            self.ootResolutionPreset = other.ootResolutionPreset
            self.ootMotionBlur = other.ootMotionBlur
        }
    }

    private static let ootManagedKeys: [String] = [
        "DM_UPSCALER",
        "DM_SHARPEN",
        "DM_FIXED_RESOLUTION",
        "DM_DYNAMIC_RESOLUTION",
        "DM_FIXED_SCALE",
        "DM_GFX_SCALE",
        "DM_MIC",
        "DM_OOT_MOTION_BLUR",
        "DM_NVN_COND_CONSERVATIVE",
        "DM_TEX_RELEASE",
        "DM_FPS_HOLD",
        "DM_THERMAL_CAP",
        "DM_RT",
        "DM_NVN_RT_LOSSY",
        "DM_NVN_POOL_SKIP_RETIRED",
        "DM_GUEST_FILE",
        "DM_GUEST_FILE_CHUNK",
        "DM_RES_PRESET",
        "DM_FRAMEGEN",
        "DM_FRAMEGEN_MAXK",
        "DM_PRESENT_LINK",
        "DM_SLOWFRAME",
        "DM_SCREEN_MATCH"
    ]

    private static var mainScreenSupports120Hz: Bool {
        let maxHz = NSScreen.main?.maximumFramesPerSecond ?? 60
        return maxHz >= 120
    }

    private func ootEnvironmentEntries(includeGuestFile: Bool = true) -> [(String, String)] {
        let posixLocale = Locale(identifier: "en_US_POSIX")
        let usePotatoPreset = (ootResolutionPreset.lowercased() == "potato")
        let useGuestFile = oot16GBRamMode && Self.tempHasSpaceForGuestFile
        let clampedMaxK = min(max(ootFrameGenMaxK, 2), 4)
        let clampedScaleTier = min(max(ootGfxScaleTier, 0), 2)
        let use120HzLink = enable60FPS && Self.mainScreenSupports120Hz
        var entries: [(String, String)] = [
            ("DM_UPSCALER", ootUpscalerMode),
            ("DM_SHARPEN", String(format: "%.2f", locale: posixLocale, ootSharpen)),
            ("DM_FIXED_RESOLUTION", ootFixedResolution ? "1" : "0"),
            ("DM_DYNAMIC_RESOLUTION", ootFixedResolution ? "0" : "1"),
            ("DM_FIXED_SCALE", String(format: "%.2f", locale: posixLocale, ootFixedScale)),
            ("DM_GFX_SCALE", "\(clampedScaleTier)"),
            ("DM_MIC", ootMicrophone ? "1" : "0"),
            ("DM_OOT_MOTION_BLUR", ootMotionBlur ? "1" : "0"),
            ("DM_NVN_COND_CONSERVATIVE", "1"),
            ("DM_FPS_HOLD", "off"),
            ("DM_THERMAL_CAP", "0"),
            ("DM_RT", "0"),
            ("DM_NVN_RT_LOSSY", "1"),
            ("DM_NVN_POOL_SKIP_RETIRED", "1"),
            ("DM_TEX_RELEASE", "0")
        ]
        if includeGuestFile {
            entries.append(("DM_GUEST_FILE", useGuestFile ? "1" : "0"))
            if useGuestFile {
                entries.append(("DM_GUEST_FILE_CHUNK", "1G"))
            }
        } else if !oot16GBRamMode {
            // On iOS, omitting DM_GUEST_FILE lets hle_svc.c auto-enable sparse guest files via os_proc_available_memory().
            entries.append(("DM_GUEST_FILE", "0"))
        }
        entries.append(("DM_RES_PRESET", usePotatoPreset ? "1" : "0"))
        if ootExperimentalFrameGen {
            entries.append(("DM_FRAMEGEN", "1"))
            entries.append(("DM_SLOWFRAME", "1"))
            entries.append(("DM_FRAMEGEN_MAXK", use120HzLink ? "\(clampedMaxK)" : "2"))
            entries.append(("DM_PRESENT_LINK", use120HzLink ? "2" : "1"))
            entries.append(("DM_SCREEN_MATCH", use120HzLink ? "0" : "1"))
        } else {
            entries.append(("DM_FRAMEGEN", "0"))
            entries.append(("DM_SLOWFRAME", "0"))
            entries.append(("DM_SCREEN_MATCH", "1"))
        }

        return entries
    }
    
    public func toEnvironmentDict(for game: PortedGame? = nil, savePath: String? = nil) -> [String: String] {
        let posixLocale = Locale(identifier: "en_US_POSIX")
        let clampedMaxK = min(max(ootFrameGenMaxK, 2), 4)
        let use120HzLink = enable60FPS && Self.mainScreenSupports120Hz
        var dict: [String: String] = [
            "DM_FPS_TARGET": enable60FPS ? "60" : "30",
            "DM_METAL_HUD": enableMetalHUD ? "1" : "0",
            "DM_OPMODE": isDockedMode ? "1" : "0",
            "DM_RENDER_SCALE": String(format: "%.2f", locale: posixLocale, renderScale),
            "DM_PRESENT_UPSCALE": enableMetalFXUpscale ? "metalfx" : "off",
            "DM_FULLSCREEN": enableGameMode ? "1" : "0",
            "DM_ENABLE_GAMEPAD_PROFILE": enableGamepadProfile ? "1" : "0",
            "DM_DISABLE_GAMEPAD_REMAP": enableGamepadProfile ? "0" : "1",
            "DM_LAUNCHER": "0"
        ]
        if ootExperimentalFrameGen {
            dict["DM_FRAMEGEN"] = "1"
            dict["DM_SLOWFRAME"] = "1"
            if use120HzLink {
                // 60 -> 120 FPS (120+ Hz display)
                dict["DM_FRAMEGEN_MAXK"] = "\(clampedMaxK)"
                dict["DM_PRESENT_LINK"] = "2"
                dict["DM_SCREEN_MATCH"] = "0"
            } else {
                // 30 -> 60 FPS (60 Hz display or 30 FPS base target)
                dict["DM_FRAMEGEN_MAXK"] = "2"
                dict["DM_PRESENT_LINK"] = "1"
                dict["DM_SCREEN_MATCH"] = "1"
            }
        } else {
            dict["DM_FRAMEGEN"] = "0"
            dict["DM_SLOWFRAME"] = "0"
            dict["DM_SCREEN_MATCH"] = "1"
        }
        if let sp = savePath, !sp.isEmpty {
            dict["DM_SAVE"] = sp
        }
        if let lang = gameLanguage?.trimmingCharacters(in: .whitespacesAndNewlines), !lang.isEmpty {
            dict["DM_LANG"] = lang
        }
        
        if let g = game {
            let tid = g.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: g.name)
            if let tid = tid, !tid.isEmpty,
               let overlay = ModManagerService.shared.buildRomfsOverlayString(for: tid, appURL: g.url) {
                dict["DM_ROMFS_OVERLAY"] = overlay
            }
        }
        
        if let g = game, Self.isOotGame(g) {
            for (key, value) in ootEnvironmentEntries() where !value.isEmpty {
                dict[key] = value
            }
        }
        return dict
    }
    
    public func envFileContent() -> String {
        let posixLocale = Locale(identifier: "en_US_POSIX")
        var text = """
        # nxnative runtime configuration
        DM_FPS_TARGET=\(enable60FPS ? "60" : "30")
        DM_METAL_HUD=\(enableMetalHUD ? "1" : "0")
        DM_OPMODE=\(isDockedMode ? "1" : "0")
        DM_RENDER_SCALE=\(String(format: "%.2f", locale: posixLocale, renderScale))
        DM_PRESENT_UPSCALE=\(enableMetalFXUpscale ? "metalfx" : "off")
        DM_FULLSCREEN=\(enableGameMode ? "1" : "0")
        DM_ENABLE_GAMEPAD_PROFILE=\(enableGamepadProfile ? "1" : "0")
        DM_DISABLE_GAMEPAD_REMAP=\(enableGamepadProfile ? "0" : "1")
        DM_LAUNCHER=0
        """
        if let pid = controllerProfileId, !pid.isEmpty {
            text += "\nDM_CONTROLLER_PROFILE_ID=\(pid)"
        }
        if let lang = gameLanguage?.trimmingCharacters(in: .whitespacesAndNewlines), !lang.isEmpty {
            text += "\nDM_LANG=\(lang)"
        }
        return text
    }

    /// Generates an `env.txt` tailored for iOS Standalone `.ipa` (`Documents/env.txt`) and `NxN Launcher` (`Documents/games/<TID>/env.txt`).
    /// Omits macOS-only keys (`DM_FULLSCREEN`, gamepad profile UUIDs) and does not clamp iOS guest memory using the Mac's disk space.
    public func iosEnvFileContent(for game: PortedGame? = nil, syncToken: String? = nil) -> String {
        let posixLocale = Locale(identifier: "en_US_POSIX")
        var lines: [String] = ["# nxnative runtime configuration"]
        if let token = syncToken, !token.isEmpty {
            lines.append("# nxnative-sync=\(token)")
        }
        lines.append("DM_FPS_TARGET=\(enable60FPS ? "60" : "30")")
        lines.append("DM_METAL_HUD=\(enableMetalHUD ? "1" : "0")")
        lines.append("DM_OPMODE=\(isDockedMode ? "1" : "0")")
        lines.append("DM_RENDER_SCALE=\(String(format: "%.2f", locale: posixLocale, renderScale))")
        lines.append("DM_PRESENT_UPSCALE=\(enableMetalFXUpscale ? "metalfx" : "off")")
        lines.append("DM_LAUNCHER=0")
        if let lang = gameLanguage?.trimmingCharacters(in: .whitespacesAndNewlines), !lang.isEmpty {
            lines.append("DM_LANG=\(lang)")
        }
        let isOot = game.map(Self.isOotGame) ?? false
        if let g = game, let tid = g.titleId ?? CompatibilityService.shared.findTitleId(forGameTitle: g.name), !tid.isEmpty {
            if let overlay = ModManagerService.shared.buildRomfsOverlayString(for: tid, appURL: g.url) {
                lines.append("DM_ROMFS_OVERLAY=\(overlay)")
            }
        }
        if isOot {
            for (key, value) in ootEnvironmentEntries(includeGuestFile: false) where !value.isEmpty {
                lines.append("\(key)=\(value)")
            }
        } else if ootExperimentalFrameGen {
            let clampedMaxK = min(max(ootFrameGenMaxK, 2), 4)
            lines.append("DM_FRAMEGEN=1")
            lines.append("DM_SLOWFRAME=1")
            lines.append("DM_FRAMEGEN_MAXK=\(clampedMaxK)")
            lines.append("DM_PRESENT_LINK=1")
            lines.append("DM_SCREEN_MATCH=1")
        }
        return lines.joined(separator: "\n") + "\n"
    }
    
    public static func defaultOotConfig() -> GameRuntimeConfig {
        return GameRuntimeConfig(
            enable60FPS: true,
            enableMetalHUD: false,
            isDockedMode: true, // Native 1080p Docked output (avoids 720p -> 1080p upscale)
            renderScale: 1.0,
            enableMetalFXUpscale: false, // No present spatial upscale (avoids 1080p -> 2560x1440 upscale)
            enableGameMode: true, // Game Mode on (fullscreen)
            enableGamepadProfile: true,
            controllerProfileId: nil,
            playerProfileIds: nil,
            ootUpscalerMode: "off", // Direct native output (bypass NDSR without downscale/upscale passes)
            ootSharpen: 0.25, // Subtle CAS Sharpening when active
            ootFixedResolution: true, // Lock internal render scale to 100% native (DM_DYNAMIC_RESOLUTION=0)
            ootFixedScale: 1.0,
            ootGfxScaleTier: 0, // Tier 0 = 100% Native (avoids 1536x864 -> 1080p Switch 2 scale)
            ootMicrophone: true, // Microphone support (ocarina on)
            oot16GBRamMode: default16GBRamMode, // Auto-enable guarded DM_GUEST_FILE on <= 16 GB RAM Macs (DM_TEX_RELEASE=0)
            ootResolutionPreset: "normal",
            ootExperimentalFrameGen: false,
            ootFrameGenMaxK: 4,
            ootMotionBlur: true
        )
    }
    
    public static func isOotGame(_ game: PortedGame) -> Bool {
        if game.platform == .nonSwitch { return false }
        if game.titleId?.uppercased() == "0400486024DEC000" { return true }
        if game.name.localizedCaseInsensitiveContains("Ocarina") { return true }
        if let bid = game.bundleId, bid.localizedCaseInsensitiveContains("0400486024dec000") { return true }
        if LibraryScanner.shared.isOcarinaOfTime(at: game.url) { return true }
        return false
    }

    public static func storageKey(for game: PortedGame) -> String {
        return "NXNative_GameConfig_" + game.uniqueKey
    }
    
    private static func resolvedLanguageConfig(_ baseConfig: GameRuntimeConfig, for game: PortedGame) -> GameRuntimeConfig {
        var config = baseConfig
        let supported = LibraryScanner.shared.supportedGameLanguages(at: game.url)
        let plistDefault = LibraryScanner.shared.defaultGameLanguage(at: game.url)
        let raw = config.gameLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lang = raw, !lang.isEmpty, supported.contains(lang) {
            config.gameLanguage = lang
        } else if supported.contains(plistDefault) {
            config.gameLanguage = plistDefault
        } else {
            config.gameLanguage = supported.first ?? plistDefault
        }
        return config
    }

    public static func load(for game: PortedGame) -> GameRuntimeConfig {
        let key = storageKey(for: game)
        let isOot = isOotGame(game)
        
        let migrationKey = "nxnative_oot_v203_glitchfree_native_" + game.uniqueKey
        if isOot && !UserDefaults.standard.bool(forKey: migrationKey) {
            UserDefaults.standard.set(true, forKey: migrationKey)
            var defOot = resolvedLanguageConfig(defaultOotConfig(), for: game)
            defOot.enableMetalHUD = preservedMetalHUDState(for: game, storageKey: key)
            withSuppressedInputProfileExport {
                defOot.save(for: game)
            }
            return defOot
        }

        var loadedConfig: GameRuntimeConfig?
        if let data = UserDefaults.standard.data(forKey: key),
           let config = try? JSONDecoder().decode(GameRuntimeConfig.self, from: data) {
            loadedConfig = config
        } else if let titleId = game.titleId, !titleId.isEmpty {
            let candidateDirs = [
                SystemDetector.shared.appSupportDirectory,
                SystemDetector.shared.defaultAppSupportDirectory
            ]
            for baseDir in candidateDirs {
                let appSup = baseDir
                    .appendingPathComponent(titleId)
                    .appendingPathComponent("env.txt")
                if let content = try? String(contentsOf: appSup, encoding: .utf8) {
                    loadedConfig = parseEnvContent(content, isOot: isOot)
                    break
                }
            }
        }

        if loadedConfig == nil {
            let bundleEnv = game.url.appendingPathComponent("Contents/Resources/dm/env.txt")
            if let content = try? String(contentsOf: bundleEnv, encoding: .utf8) {
                loadedConfig = parseEnvContent(content, isOot: isOot)
            }
        }

        if let config = loadedConfig {
            let resolved = resolvedLanguageConfig(config, for: game)
            if isOot {
                let cleanId = (game.titleId ?? "0400486024DEC000").uppercased()
                let ootHyruleFieldFixKey = "nxnative.migration.oot_hyrule_field_tex_release_v1_\(cleanId)_\(game.uniqueKey)"
                let envHasLegacyTexRelease2 = envFilesContainLegacyTexRelease2(for: game, titleId: cleanId)
                if !UserDefaults.standard.bool(forKey: ootHyruleFieldFixKey) || envHasLegacyTexRelease2 {
                    UserDefaults.standard.set(true, forKey: ootHyruleFieldFixKey)
                    withSuppressedInputProfileExport {
                        resolved.save(for: game)
                    }
                }
            }
            return resolved
        }
        
        if isOot {
            let cleanId = (game.titleId ?? "0400486024DEC000").uppercased()
            let ootHyruleFieldFixKey = "nxnative.migration.oot_hyrule_field_tex_release_v1_\(cleanId)_\(game.uniqueKey)"
            UserDefaults.standard.set(true, forKey: ootHyruleFieldFixKey)
            let defOot = resolvedLanguageConfig(defaultOotConfig(), for: game)
            defOot.save(for: game)
            return defOot
        }
        
        return resolvedLanguageConfig(GameRuntimeConfig(), for: game)
    }

    private static func envFilesContainLegacyTexRelease2(for game: PortedGame, titleId: String) -> Bool {
        var candidates: [URL] = [game.url.appendingPathComponent("Contents/Resources/dm/env.txt")]
        let baseDirs = [
            SystemDetector.shared.appSupportDirectory,
            SystemDetector.shared.defaultAppSupportDirectory
        ]
        for baseDir in baseDirs {
            for tid in Set([titleId, titleId.uppercased(), titleId.lowercased()]) {
                candidates.append(baseDir.appendingPathComponent(tid).appendingPathComponent("env.txt"))
            }
        }
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                if line.trimmingCharacters(in: .whitespaces) == "DM_TEX_RELEASE=2" {
                    return true
                }
            }
        }
        return false
    }
    
    public func save(for game: PortedGame) {
        let key = GameRuntimeConfig.storageKey(for: game)
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
        
        applyToDisk(for: game)
    }
    
    public func applyToDisk(for game: PortedGame) {
        let fm = FileManager.default
        
        // 1. Write to ~/Library/Application Support/nxnative/<titleId>/env.txt (both cases to avoid mismatch)
        let resolvedTitleId: String? = {
            guard game.platform != .nonSwitch else { return nil }
            if let tid = game.titleId, !tid.isEmpty { return tid }
            return CompatibilityService.shared.findTitleId(forGameTitle: game.name)
        }()
        let isOot = GameRuntimeConfig.isOotGame(game)
        if let titleId = resolvedTitleId, !titleId.isEmpty {
            let ids = Set([titleId, titleId.uppercased(), titleId.lowercased()])
            var baseDirs: [URL] = [SystemDetector.shared.appSupportDirectory]
            let stdDir = SystemDetector.shared.defaultAppSupportDirectory
            if stdDir.standardizedFileURL.path != SystemDetector.shared.appSupportDirectory.standardizedFileURL.path {
                baseDirs.append(stdDir)
            }
            for baseDir in baseDirs {
                for tid in ids {
                    let appSupDir = baseDir.appendingPathComponent(tid)
                    try? fm.createDirectory(at: appSupDir, withIntermediateDirectories: true)
                    let envFile = appSupDir.appendingPathComponent("env.txt")
                    let existing = try? String(contentsOf: envFile, encoding: .utf8)
                    let content = mergedEnvContent(existing: existing, isOot: isOot, titleId: tid, appURL: game.url)
                    try? content.write(to: envFile, atomically: true, encoding: .utf8)
                }
            }
        }
        
        // 2. Also write to <Game.app>/Contents/Resources/dm/env.txt
        let dmDir = game.url.appendingPathComponent("Contents/Resources/dm")
        if fm.fileExists(atPath: dmDir.path) {
            let bundleEnv = dmDir.appendingPathComponent("env.txt")
            let existing = try? String(contentsOf: bundleEnv, encoding: .utf8)
            let content = mergedEnvContent(existing: existing, isOot: isOot, titleId: resolvedTitleId, appURL: game.url)
            try? content.write(to: bundleEnv, atomically: true, encoding: .utf8)
        }
        
        // 3. Export resolved controller/keyboard mapping to the macOS game bundle
        if game.platform != .ios && !Self.isInputProfileExportSuppressed {
            InputProfileManager.shared.exportMapping(for: game, config: self)
        }

        // 4. Synchronize macOS Game Mode (LSSupportsGameMode) & Game Language (DMLanguage / CFPreferences)
        if game.platform != .ios {
            var langToSync: String? = nil
            if game.platform == .macApp {
                let trimmedLang = self.gameLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedLang = (trimmedLang.flatMap { $0.isEmpty ? nil : $0 }) ?? LibraryScanner.shared.defaultGameLanguage(at: game.url)
                langToSync = resolvedLang

                let plistURL = game.url.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: plistURL),
                   let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                   let bundleId = plist["CFBundleIdentifier"] as? String, !bundleId.isEmpty {
                    CFPreferencesSetAppValue("launcher.DM_LANG" as CFString, resolvedLang as CFString, bundleId as CFString)
                    CFPreferencesAppSynchronize(bundleId as CFString)
                }
            }
            LibraryScanner.shared.synchronizeGameModeInfoPlist(at: game.url, enableGameMode: self.enableGameMode, gameLanguage: langToSync)
        }
    }

    private func mergedEnvContent(existing: String?, isOot: Bool = false, titleId: String? = nil, appURL: URL? = nil) -> String {
        let baseManagedKeys = ["DM_FPS_TARGET", "DM_METAL_HUD", "DM_OPMODE", "DM_RENDER_SCALE", "DM_PRESENT_UPSCALE", "DM_FULLSCREEN", "DM_ENABLE_GAMEPAD_PROFILE", "DM_DISABLE_GAMEPAD_REMAP", "DM_LAUNCHER", "DM_CONTROLLER_PROFILE_ID", "DM_LANG", "DM_ROMFS_OVERLAY"]
        let managedKeys = isOot ? (baseManagedKeys + Self.ootManagedKeys) : baseManagedKeys
        var preservedLines: [String] = []
        if let existing = existing {
            for line in existing.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                }
                let isManaged = managedKeys.contains { k in
                    trimmed.hasPrefix("\(k)=")
                }
                if !isManaged {
                    preservedLines.append(trimmed)
                }
            }
        }
        var outputLines = envFileContent().components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let tid = titleId, !tid.isEmpty,
           let overlay = ModManagerService.shared.buildRomfsOverlayString(for: tid, appURL: appURL) {
            outputLines.append("DM_ROMFS_OVERLAY=\(overlay)")
        }
        if isOot {
            for (key, value) in ootEnvironmentEntries() where !value.isEmpty {
                outputLines.append("\(key)=\(value)")
            }
        }
        for preserved in preservedLines {
            outputLines.append(preserved)
        }
        return outputLines.joined(separator: "\n") + "\n"
    }
    
    private static func parseEnvContent(_ text: String, isOot: Bool = false) -> GameRuntimeConfig {
        var config = isOot ? defaultOotConfig() : GameRuntimeConfig()
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || !trimmed.contains("=") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            
            switch key {
            case "DM_FPS_TARGET":
                config.enable60FPS = (val == "60")
            case "DM_METAL_HUD":
                config.enableMetalHUD = (val == "1")
            case "DM_OPMODE":
                config.isDockedMode = (val != "0")
            case "DM_RENDER_SCALE":
                if let scale = Double(val), scale >= 0.5 && scale <= 1.0 {
                    config.renderScale = scale
                }
            case "DM_PRESENT_UPSCALE":
                config.enableMetalFXUpscale = (val.lowercased() == "metalfx" || val == "1")
            case "DM_FULLSCREEN":
                config.enableGameMode = (val != "0")
            case "DM_ENABLE_GAMEPAD_PROFILE":
                config.enableGamepadProfile = (val != "0")
            case "DM_DISABLE_GAMEPAD_REMAP":
                config.enableGamepadProfile = (val != "1")
            case "DM_CONTROLLER_PROFILE_ID":
                config.controllerProfileId = val.isEmpty ? nil : val
            case "DM_LANG":
                config.gameLanguage = val.isEmpty ? nil : val
            case "DM_UPSCALER":
                config.ootUpscalerMode = val.lowercased()
            case "DM_SHARPEN":
                if let s = Double(val), s >= 0.0 && s <= 1.0 {
                    config.ootSharpen = s
                }
            case "DM_FIXED_RESOLUTION":
                config.ootFixedResolution = (val == "1")
            case "DM_DYNAMIC_RESOLUTION":
                config.ootFixedResolution = (val == "0")
            case "DM_FIXED_SCALE":
                if let s = Double(val), s >= 0.5 && s <= 1.0 {
                    config.ootFixedScale = s
                }
            case "DM_GFX_SCALE":
                if let tier = Int(val), tier >= 0 && tier <= 2 {
                    config.ootGfxScaleTier = tier
                }
            case "DM_MIC":
                config.ootMicrophone = (val == "1")
            case "DM_OOT_MOTION_BLUR":
                config.ootMotionBlur = (val != "0")
            case "DM_RES_PRESET":
                config.ootResolutionPreset = (val == "1") ? "potato" : "normal"
            case "DM_TEX_RELEASE":
                if val == "0" || val == "2" {
                    config.oot16GBRamMode = true
                } else if val == "1" {
                    config.oot16GBRamMode = false
                }
            case "DM_GUEST_FILE":
                if val == "1" {
                    config.oot16GBRamMode = true
                }
            case "DM_FRAMEGEN":
                config.ootExperimentalFrameGen = (val == "1")
            case "DM_FRAMEGEN_MAXK":
                if let k = Int(val), k >= 2 && k <= 4 {
                    config.ootFrameGenMaxK = k
                }
            default:
                break
            }
        }
        return config
    }
}
