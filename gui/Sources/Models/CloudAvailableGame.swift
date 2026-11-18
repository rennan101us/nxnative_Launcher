import Foundation

public struct CloudAvailableGame: Identifiable, Codable, Equatable {
    public var id: String { "\(sourceId.uuidString)_\(titleId)_\(downloadURL.hashValue)" }
    public let titleId: String
    public let gameTitle: String
    public let matchedVersion: String
    public var downloadURL: String
    public var isTorrent: Bool
    public let fileSizeFormatted: String
    public let sourceId: UUID
    public let sourceName: String
    
    public init(
        titleId: String,
        gameTitle: String,
        matchedVersion: String = "",
        downloadURL: String,
        isTorrent: Bool = false,
        fileSizeFormatted: String = "",
        sourceId: UUID,
        sourceName: String
    ) {
        self.titleId = titleId
        self.gameTitle = gameTitle
        self.matchedVersion = matchedVersion
        self.downloadURL = downloadURL
        self.isTorrent = isTorrent
        self.fileSizeFormatted = fileSizeFormatted
        self.sourceId = sourceId
        self.sourceName = sourceName
    }
}
