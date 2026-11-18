import Foundation

public struct CloudGameSource: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var urlString: String
    public var isEnabled: Bool
    public var lastSyncDate: Date?
    public var lastItemCount: Int
    public var lastErrorMessage: String?
    
    public init(
        id: UUID = UUID(),
        name: String,
        urlString: String,
        isEnabled: Bool = true,
        lastSyncDate: Date? = nil,
        lastItemCount: Int = 0,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.isEnabled = isEnabled
        self.lastSyncDate = lastSyncDate
        self.lastItemCount = lastItemCount
        self.lastErrorMessage = lastErrorMessage
    }
}
