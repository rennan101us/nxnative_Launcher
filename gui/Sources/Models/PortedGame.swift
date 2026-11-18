import Foundation
import AppKit

public struct PortedGame: Identifiable, Hashable, Codable {
    public let id: UUID
    public let name: String
    public let url: URL
    public let platform: TargetPlatform
    public let sizeBytes: Int64
    public let modificationDate: Date
    public let bundleId: String?
    public let titleId: String?
    public let versionString: String?
    
    enum CodingKeys: String, CodingKey {
        case name, url, platform, sizeBytes, modificationDate, bundleId, titleId, versionString
    }
    
    public init(
        name: String,
        url: URL,
        platform: TargetPlatform,
        sizeBytes: Int64,
        modificationDate: Date,
        bundleId: String? = nil,
        titleId: String? = nil,
        versionString: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.platform = platform
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
        self.bundleId = bundleId
        self.titleId = titleId
        self.versionString = versionString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.url = try container.decode(URL.self, forKey: .url)
        self.platform = try container.decode(TargetPlatform.self, forKey: .platform)
        self.sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        self.modificationDate = try container.decode(Date.self, forKey: .modificationDate)
        self.bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId)
        self.titleId = try container.decodeIfPresent(String.self, forKey: .titleId)
        self.versionString = try container.decodeIfPresent(String.self, forKey: .versionString)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(platform, forKey: .platform)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(modificationDate, forKey: .modificationDate)
        try container.encodeIfPresent(bundleId, forKey: .bundleId)
        try container.encodeIfPresent(titleId, forKey: .titleId)
        try container.encodeIfPresent(versionString, forKey: .versionString)
    }
    
    public var uniqueKey: String {
        if let tid = titleId, !tid.isEmpty { return tid }
        if let bid = bundleId, !bid.isEmpty { return bid }
        return name
    }

    /// Globally unique, scan-stable identity distinguishing `.app` and `.ipa` builds of the same Title ID.
    public var stableId: String {
        url.standardizedFileURL.path
    }
    
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    
    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: modificationDate)
    }
    
    public var isPlayableLocally: Bool {
        platform == .macApp || platform == .nonSwitch
    }
    
    public var isSwitch2: Bool {
        guard let tid = titleId?.uppercased(), !tid.isEmpty else { return false }
        return tid.hasPrefix("0400")
    }
    
    public var isSwitch1: Bool {
        guard let tid = titleId?.uppercased(), !tid.isEmpty else { return false }
        return tid.hasPrefix("0100")
    }
}
