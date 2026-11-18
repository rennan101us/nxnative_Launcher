import Foundation

public struct GamePreset: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var titleId: String?
    public var isBuiltIn: Bool
    public var config: GameRuntimeConfig
    public var createdAt: Date
    public var notes: String?

    public init(
        id: UUID = UUID(),
        name: String,
        titleId: String? = nil,
        isBuiltIn: Bool = false,
        config: GameRuntimeConfig,
        createdAt: Date = Date(),
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.titleId = titleId
        self.isBuiltIn = isBuiltIn
        self.config = config
        self.createdAt = createdAt
        self.notes = notes
    }
}

public struct GamePresetMetadata: Codable, Equatable {
    public static let currentFormatVersion: Int = 1
    public static let expectedMagic: String = "NXN_PRESET"

    public let magic: String
    public let formatVersion: Int
    public let presetName: String
    public let titleId: String?
    public let gameName: String?
    public let appVersion: String
    public let createdAt: Date
    public let notes: String?

    public init(
        presetName: String,
        titleId: String? = nil,
        gameName: String? = nil,
        appVersion: String = "2.2.0",
        createdAt: Date = Date(),
        notes: String? = nil
    ) {
        self.magic = Self.expectedMagic
        self.formatVersion = Self.currentFormatVersion
        self.presetName = presetName
        self.titleId = titleId
        self.gameName = gameName
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.notes = notes
    }
}
