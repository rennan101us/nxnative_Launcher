import Foundation
import CryptoKit
import AppKit

public final class GamePresetService: ObservableObject {
    public static let shared = GamePresetService()

    public enum PresetError: LocalizedError {
        case invalidHeader
        case invalidMetadata
        case decryptionFailed
        case encryptionFailed
        case fileNotFound
        case writeFailed

        public var errorDescription: String? {
            switch self {
            case .invalidHeader:
                return "Invalid or corrupted .nxn preset header."
            case .invalidMetadata:
                return "Could not parse .nxn preset metadata."
            case .decryptionFailed:
                return "Failed to decrypt preset payload (invalid or tampered file)."
            case .encryptionFailed:
                return "Failed to encrypt preset payload."
            case .fileNotFound:
                return "Preset file not found."
            case .writeFailed:
                return "Could not write preset to disk."
            }
        }
    }

    private static let magicHeader: [UInt8] = [
        0x4E, 0x58, 0x4E, 0x5F, 0x50, 0x52, 0x45, 0x53, 0x45, 0x54, 0x01, 0x00
    ] // "NXN_PRESET\x01\x00" (12 bytes)

    private let fileManager = FileManager.default

    public var basePresetsDirectory: URL {
        let dir = SystemDetector.shared.appSupportDirectory.appendingPathComponent("presets", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public func presetsDirectory(for game: PortedGame) -> URL {
        let titleId = resolvedTitleId(for: game)
        let dir = basePresetsDirectory.appendingPathComponent(titleId, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func resolvedTitleId(for game: PortedGame) -> String {
        if let tid = game.titleId, !tid.isEmpty {
            return tid.uppercased()
        }
        let found = CompatibilityService.shared.findTitleId(forGameTitle: game.name)
        if let f = found, !f.isEmpty {
            return f.uppercased()
        }
        return game.name.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Crypto Key Derivation

    private func deriveSymmetricKey() -> SymmetricKey {
        let inputKeyMaterial = SymmetricKey(data: "NxNative_NxN_Preset_Secret_Key_2026".data(using: .utf8)!)
        let salt = "NxNative_Preset_v1_Salt".data(using: .utf8)!
        let info = "NxNative_Preset_Payload_AES256GCM".data(using: .utf8)!
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKeyMaterial, salt: salt, info: info, outputByteCount: 32)
    }

    // MARK: - Encrypt / Decrypt .nxn

    public func packageAndEncrypt(preset: GamePreset, for game: PortedGame? = nil) throws -> Data {
        let metadata = GamePresetMetadata(
            presetName: preset.name,
            titleId: preset.titleId ?? (game != nil ? resolvedTitleId(for: game!) : nil),
            gameName: game?.name,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2.4",
            createdAt: preset.createdAt,
            notes: preset.notes
        )

        let metaData = try JSONEncoder().encode(metadata)
        var metaLen = UInt32(metaData.count).bigEndian
        let metaLenData = withUnsafeBytes(of: &metaLen) { Data($0) }

        let payloadData = try JSONEncoder().encode(preset.config)
        let key = deriveSymmetricKey()
        let sealed = try AES.GCM.seal(payloadData, using: key)
        guard let combined = sealed.combined else {
            throw PresetError.encryptionFailed
        }

        var fullData = Data(Self.magicHeader)
        fullData.append(metaLenData)
        fullData.append(metaData)
        fullData.append(combined)
        return fullData
    }

    public func unpackAndDecrypt(from data: Data) throws -> (metadata: GamePresetMetadata, config: GameRuntimeConfig) {
        guard data.count >= Self.magicHeader.count + 4 + 1 + 28 else {
            throw PresetError.invalidHeader
        }

        let magicInFile = Array(data.prefix(Self.magicHeader.count))
        guard magicInFile == Self.magicHeader else {
            throw PresetError.invalidHeader
        }

        let metaLenOffset = Self.magicHeader.count
        let metaLenSub = data.subdata(in: metaLenOffset..<(metaLenOffset + 4))
        let metaLen = Int(metaLenSub.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })

        let metaStart = metaLenOffset + 4
        let metaEnd = metaStart + metaLen
        guard metaEnd < data.count else {
            throw PresetError.invalidMetadata
        }

        let metaData = data.subdata(in: metaStart..<metaEnd)
        let metadata: GamePresetMetadata
        do {
            metadata = try JSONDecoder().decode(GamePresetMetadata.self, from: metaData)
        } catch {
            throw PresetError.invalidMetadata
        }

        let cipherData = data.subdata(in: metaEnd..<data.count)
        let key = deriveSymmetricKey()
        let decryptedData: Data
        do {
            let sealed = try AES.GCM.SealedBox(combined: cipherData)
            decryptedData = try AES.GCM.open(sealed, using: key)
        } catch {
            throw PresetError.decryptionFailed
        }

        let config: GameRuntimeConfig
        do {
            config = try JSONDecoder().decode(GameRuntimeConfig.self, from: decryptedData)
        } catch {
            throw PresetError.decryptionFailed
        }

        return (metadata, config)
    }

    // MARK: - Built-in Presets

    public func builtInPresets(for game: PortedGame) -> [GamePreset] {
        let isOot = GameRuntimeConfig.isOotGame(game)
        let tid = resolvedTitleId(for: game)

        if isOot {
            // Zelda OoT Special Presets (tuned around user-verified smooth-60FPS MetalFX + FrameGen profile)
            let oot720p60 = GameRuntimeConfig(
                enable60FPS: false, // 30 FPS native base + 2x FrameGen reaches ~60 FPS smoothly without CPU/GPU stalls
                enableMetalHUD: false,
                isDockedMode: false, // Handheld 720p
                renderScale: 1.0,
                enableMetalFXUpscale: false,
                enableGameMode: true,
                enableGamepadProfile: true,
                ootUpscalerMode: "metalfx",
                ootSharpen: 1.0,
                ootFixedResolution: true,
                ootFixedScale: 1.0,
                ootGfxScaleTier: 2,
                ootMicrophone: true,
                oot16GBRamMode: true,
                ootResolutionPreset: "normal",
                ootExperimentalFrameGen: true,
                ootFrameGenMaxK: 2
            )

            let oot1080p60 = GameRuntimeConfig(
                enable60FPS: false, // 30 FPS native base + 2x FrameGen reaches ~60 FPS smoothly at 1080p
                enableMetalHUD: false,
                isDockedMode: true, // Docked 1080p
                renderScale: 1.0,
                enableMetalFXUpscale: false,
                enableGameMode: true,
                enableGamepadProfile: true,
                ootUpscalerMode: "metalfx",
                ootSharpen: 1.0,
                ootFixedResolution: true,
                ootFixedScale: 1.0,
                ootGfxScaleTier: 2,
                ootMicrophone: true,
                oot16GBRamMode: true,
                ootResolutionPreset: "normal",
                ootExperimentalFrameGen: true,
                ootFrameGenMaxK: 2
            )

            return [
                GamePreset(
                    name: "720p/60fps (Smooth 60)",
                    titleId: tid,
                    isBuiltIn: true,
                    config: oot720p60,
                    notes: "Handheld 720p + MetalFX (Sharpen 1.0) + 2x FrameGen (30 FPS base), Tier 2 GFX Scale, Glitch-Free Low-RAM Mode."
                ),
                GamePreset(
                    name: "1080p/60fps (Smooth 60)",
                    titleId: tid,
                    isBuiltIn: true,
                    config: oot1080p60,
                    notes: "Docked 1080p + MetalFX (Sharpen 1.0) + 2x FrameGen (30 FPS base), Tier 2 GFX Scale, Glitch-Free Low-RAM Mode."
                ),
                GamePreset(
                    name: "Default Recommended",
                    titleId: tid,
                    isBuiltIn: true,
                    config: GameRuntimeConfig.defaultOotConfig(),
                    notes: "Factory default native 1:1 enhanced OoT profile."
                )
            ]
        }

        // Generic Switch Mac Port Presets
        let def60 = GameRuntimeConfig(
            enable60FPS: true,
            enableMetalHUD: false,
            isDockedMode: true,
            renderScale: 1.0,
            enableMetalFXUpscale: false,
            enableGameMode: true,
            enableGamepadProfile: true,
            ootExperimentalFrameGen: false
        )

        let perf720 = GameRuntimeConfig(
            enable60FPS: true,
            enableMetalHUD: false,
            isDockedMode: false,
            renderScale: 1.0,
            enableMetalFXUpscale: false,
            enableGameMode: true,
            enableGamepadProfile: true,
            ootExperimentalFrameGen: false
        )

        let battery30 = GameRuntimeConfig(
            enable60FPS: false,
            enableMetalHUD: false,
            isDockedMode: false,
            renderScale: 0.85,
            enableMetalFXUpscale: false,
            enableGameMode: true,
            enableGamepadProfile: true,
            ootExperimentalFrameGen: false
        )

        let promotion120 = GameRuntimeConfig(
            enable60FPS: true,
            enableMetalHUD: false,
            isDockedMode: true,
            renderScale: 1.0,
            enableMetalFXUpscale: false,
            enableGameMode: true,
            enableGamepadProfile: true,
            ootExperimentalFrameGen: true,
            ootFrameGenMaxK: 4
        )

        return [
            GamePreset(
                name: "Default Recommended (60 FPS)",
                titleId: tid,
                isBuiltIn: true,
                config: def60,
                notes: "Balanced 1080p 60 FPS profile."
            ),
            GamePreset(
                name: "High Performance (720p / 60 FPS)",
                titleId: tid,
                isBuiltIn: true,
                config: perf720,
                notes: "Handheld 720p mode for maximum framerate stability."
            ),
            GamePreset(
                name: "Battery Saver (30 FPS)",
                titleId: tid,
                isBuiltIn: true,
                config: battery30,
                notes: "Locked 30 FPS handheld mode for energy efficiency."
            ),
            GamePreset(
                name: "Smooth ProMotion (Framegen 120 FPS)",
                titleId: tid,
                isBuiltIn: true,
                config: promotion120,
                notes: "60 FPS doubled to 120 FPS via Metal Framegen on ProMotion screens."
            )
        ]
    }

    // MARK: - User Custom Presets

    public func userPresets(for game: PortedGame) -> [GamePreset] {
        let dir = presetsDirectory(for: game)
        guard let items = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        var results: [GamePreset] = []
        for file in items where file.pathExtension.lowercased() == "nxn" {
            guard let data = try? Data(contentsOf: file),
                  let (meta, config) = try? unpackAndDecrypt(from: data) else {
                continue
            }
            let preset = GamePreset(
                id: UUID(),
                name: meta.presetName,
                titleId: meta.titleId,
                isBuiltIn: false,
                config: config,
                createdAt: meta.createdAt,
                notes: meta.notes
            )
            results.append(preset)
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func allPresets(for game: PortedGame) -> [GamePreset] {
        return builtInPresets(for: game) + userPresets(for: game)
    }

    public func saveCustomPreset(name: String, config: GameRuntimeConfig, for game: PortedGame) throws -> GamePreset {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw PresetError.invalidMetadata
        }

        var cleanName = trimmedName
        while cleanName.lowercased().hasSuffix(".nxn") {
            cleanName = String(cleanName.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cleanName.isEmpty else {
            throw PresetError.invalidMetadata
        }

        let tid = resolvedTitleId(for: game)
        let preset = GamePreset(
            name: cleanName,
            titleId: tid,
            isBuiltIn: false,
            config: config,
            createdAt: Date()
        )

        let data = try packageAndEncrypt(preset: preset, for: game)
        let safeFilename = sanitizeFilename(cleanName) + ".nxn"
        let dest = presetsDirectory(for: game).appendingPathComponent(safeFilename)
        try data.write(to: dest, options: .atomic)
        return preset
    }

    public func deleteUserPreset(_ preset: GamePreset, for game: PortedGame) {
        guard !preset.isBuiltIn else { return }
        var cleanName = preset.name
        while cleanName.lowercased().hasSuffix(".nxn") {
            cleanName = String(cleanName.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let safeFilename = sanitizeFilename(cleanName) + ".nxn"
        let dest = presetsDirectory(for: game).appendingPathComponent(safeFilename)
        try? fileManager.removeItem(at: dest)
    }

    // MARK: - Export and Import

    public func exportPreset(_ preset: GamePreset, for game: PortedGame, to destinationURL: URL) throws {
        var path = destinationURL.path
        while path.lowercased().hasSuffix(".nxn.nxn") {
            path = String(path.dropLast(4))
        }
        if !path.lowercased().hasSuffix(".nxn") {
            path += ".nxn"
        }
        let finalURL = URL(fileURLWithPath: path)
        let data = try packageAndEncrypt(preset: preset, for: game)
        try data.write(to: finalURL, options: .atomic)
    }

    public func importPreset(from fileURL: URL, for game: PortedGame) throws -> GamePreset {
        let data = try Data(contentsOf: fileURL)
        let (meta, config) = try unpackAndDecrypt(from: data)

        let preset = GamePreset(
            name: meta.presetName,
            titleId: resolvedTitleId(for: game),
            isBuiltIn: false,
            config: config,
            createdAt: meta.createdAt,
            notes: meta.notes
        )

        // Save imported preset into user presets directory
        _ = try saveCustomPreset(name: preset.name, config: preset.config, for: game)
        return preset
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }
}
