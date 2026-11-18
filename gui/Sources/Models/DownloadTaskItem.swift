import Foundation

public enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

public struct DownloadTaskItem: Identifiable, Equatable {
    public let id: UUID
    public let titleId: String
    public let gameTitle: String
    public var progress: Double // 0.0 to 1.0
    public var speedString: String
    public var etaString: String
    public var downloadedBytes: Int64
    public var totalBytes: Int64
    public var status: DownloadStatus
    public var localDestinationURL: URL?
    public var errorMessage: String?
    
    public init(
        id: UUID = UUID(),
        titleId: String,
        gameTitle: String,
        progress: Double = 0.0,
        speedString: String = "",
        etaString: String = "",
        downloadedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        status: DownloadStatus = .queued,
        localDestinationURL: URL? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.titleId = titleId
        self.gameTitle = gameTitle
        self.progress = progress
        self.speedString = speedString
        self.etaString = etaString
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.status = status
        self.localDestinationURL = localDestinationURL
        self.errorMessage = errorMessage
    }
}
