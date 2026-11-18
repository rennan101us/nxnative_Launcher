import Foundation

public struct ReleaseHighlightCategory: Identifiable, Codable, Hashable {
    public var id: String { "\(isPrimarySection ? "p" : "s")_\(title)" }
    public let title: String
    public let icon: String
    public let colorKey: String
    public let summaryPoints: [String]
    public let detailedPoints: [String]
    public let isPrimarySection: Bool

    public init(
        title: String,
        icon: String,
        colorKey: String,
        summaryPoints: [String],
        detailedPoints: [String],
        isPrimarySection: Bool
    ) {
        self.title = title
        self.icon = icon
        self.colorKey = colorKey
        self.summaryPoints = summaryPoints
        self.detailedPoints = detailedPoints
        self.isPrimarySection = isPrimarySection
    }
}

public struct UpdateInfo {
    public let hasUpdate: Bool
    public let localCommit: String
    public let remoteCommit: String
    public let commitMessages: [String]
    public let checkDate: Date
    public let repoURL: String
    public let upstreamBehindCount: Int
    public let upstreamCommitMessages: [String]
    public let upstreamRepoURL: String
    public let releaseName: String?
    public let releaseSummary: String?
    public let releaseCategories: [ReleaseHighlightCategory]
    public let releaseMarkdown: String?

    public init(
        hasUpdate: Bool,
        localCommit: String,
        remoteCommit: String,
        commitMessages: [String],
        checkDate: Date,
        repoURL: String,
        upstreamBehindCount: Int = 0,
        upstreamCommitMessages: [String] = [],
        upstreamRepoURL: String = "https://github.com/seedds/nxnative.git",
        releaseName: String? = nil,
        releaseSummary: String? = nil,
        releaseCategories: [ReleaseHighlightCategory] = [],
        releaseMarkdown: String? = nil
    ) {
        self.hasUpdate = hasUpdate
        self.localCommit = localCommit
        self.remoteCommit = remoteCommit
        self.commitMessages = commitMessages
        self.checkDate = checkDate
        self.repoURL = repoURL
        self.upstreamBehindCount = upstreamBehindCount
        self.upstreamCommitMessages = upstreamCommitMessages
        self.upstreamRepoURL = upstreamRepoURL
        self.releaseName = releaseName
        self.releaseSummary = releaseSummary
        self.releaseCategories = releaseCategories
        self.releaseMarkdown = releaseMarkdown
    }
}

public protocol UpdateCheckerDelegate: AnyObject {
    func updateCheckerDidFindUpdate(_ info: UpdateInfo)
    func updateCheckerDidProduceLog(_ message: String)
}
