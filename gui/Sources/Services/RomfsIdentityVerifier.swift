import Foundation

/// Parsed `DMROMFSID1` identity metadata produced by `dm/host/romfs_identity.h`,
/// matching `Payload/*.app/romfs.id` and `DmGame<TitleID>.framework/game.manifest.json`.
public struct RomfsExpectedIdentity: Equatable, Sendable {
    public let rawLine: String
    public let titleId: String?
    public let displayVersion: String?
    public let buildVersion: String?
    public let expectedSize: Int64
    public let expectedIndex: UInt64?

    public init(
        rawLine: String,
        titleId: String?,
        displayVersion: String?,
        buildVersion: String?,
        expectedSize: Int64,
        expectedIndex: UInt64?
    ) {
        self.rawLine = rawLine
        self.titleId = titleId
        self.displayVersion = displayVersion
        self.buildVersion = buildVersion
        self.expectedSize = expectedSize
        self.expectedIndex = expectedIndex
    }
}

/// Shared verification helpers ensuring local `romfs.img` assets, `.ipa` bundles, and
/// `DmGame<TitleID>.framework` manifests agree strictly on byte size and `DMROMFS1` index hash
/// before anything is transferred to `NxN Launcher` on iOS.
public enum RomfsIdentityVerifier {
    private static let offsetBasis: UInt64 = 0xcbf29ce484222325
    private static let fnvPrime: UInt64 = 0x100000001b3
    private static let chunkBytes = 1 << 20
    private static let dmRomfsMagic = Array("DMROMFS1".utf8)

    private struct CacheKey: Hashable {
        let path: String
        let size: Int64
        let mtimeNs: Int64
    }

    private struct ImageDigest: Equatable {
        let size: Int64
        let index: UInt64?
        let isValidHeader: Bool
    }

    private static let cacheLock = NSLock()
    private static var ipaIdentityCache: [CacheKey: RomfsExpectedIdentity?] = [:]
    private static var embeddedSizeCache: [CacheKey: Int64?] = [:]
    private static var imageDigestCache: [CacheKey: ImageDigest] = [:]

    /// Parses a `DMROMFSID1 title=... version=... build=... size=<bytes> index=<hex>` line.
    public static func parse(_ raw: String) -> RomfsExpectedIdentity? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
        guard fields.first == "DMROMFSID1" else { return nil }

        var titleId: String?
        var displayVersion: String?
        var buildVersion: String?
        var size: Int64?
        var index: UInt64?

        for field in fields.dropFirst() {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = field[..<eq]
            let val = String(field[field.index(after: eq)...])
            switch key {
            case "title":
                titleId = val.uppercased()
            case "version":
                displayVersion = val
            case "build":
                buildVersion = val
            case "size":
                guard let v = Int64(val), v > 0 else { return nil }
                size = v
            case "index":
                if let h = UInt64(val, radix: 16) {
                    index = h
                }
            default:
                break
            }
        }

        guard let expectedSize = size else { return nil }
        return RomfsExpectedIdentity(
            rawLine: trimmed,
            titleId: titleId,
            displayVersion: displayVersion,
            buildVersion: buildVersion,
            expectedSize: expectedSize,
            expectedIndex: index
        )
    }

    /// Reads `romfs_identity` from `DmGame<TitleID>.framework/game.manifest.json`.
    public static func readIdentity(fromFramework fwURL: URL) -> RomfsExpectedIdentity? {
        let manifestURL = fwURL.appendingPathComponent("game.manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idLine = json["romfs_identity"] as? String else {
            return nil
        }
        return parse(idLine)
    }

    /// Reads `romfs.id` or embedded `DmGame*.framework/game.manifest.json` from an extracted `.app` bundle.
    public static func readIdentity(fromAppBundle appURL: URL) -> RomfsExpectedIdentity? {
        let fm = FileManager.default
        let direct = appURL.appendingPathComponent("romfs.id")
        if let text = try? String(contentsOf: direct, encoding: .utf8),
           let parsed = parse(text) {
            return parsed
        }
        let fwsDir = appURL.appendingPathComponent("Frameworks")
        if let items = try? fm.contentsOfDirectory(at: fwsDir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("DmGame") && item.pathExtension == "framework" {
                if let parsed = readIdentity(fromFramework: item) {
                    return parsed
                }
            }
        }
        return nil
    }

    /// Reads `Payload/*.app/romfs.id` (or Route C embedded framework manifest) from a `.ipa` archive.
    public static func readIdentity(fromIpa ipaURL: URL) -> RomfsExpectedIdentity? {
        let resolved = ipaURL.resolvingSymlinksInPath()
        guard let key = cacheKey(for: resolved) else { return nil }

        cacheLock.lock()
        if let cached = ipaIdentityCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var found: RomfsExpectedIdentity? = nil
        let resId = BoundedProcess.run(
            "/usr/bin/unzip",
            ["-p", resolved.path, "Payload/*.app/romfs.id"],
            timeout: 6.0
        )
        if resId.success, !resId.output.isEmpty {
            found = parse(resId.output)
        }

        if found == nil {
            let resMan = BoundedProcess.run(
                "/usr/bin/unzip",
                ["-p", resolved.path, "Payload/*.app/Frameworks/DmGame*.framework/game.manifest.json"],
                timeout: 6.0
            )
            if resMan.success,
               let data = resMan.output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let idLine = json["romfs_identity"] as? String {
                found = parse(idLine)
            }
        }

        cacheLock.lock()
        ipaIdentityCache[key] = found
        cacheLock.unlock()
        return found
    }

    /// Reads the uncompressed size of an embedded `Payload/*.app/romfs.img` inside a `.ipa`, if present.
    public static func readEmbeddedRomfsSize(inIpa ipaURL: URL) -> Int64? {
        let resolved = ipaURL.resolvingSymlinksInPath()
        guard let key = cacheKey(for: resolved) else { return nil }

        cacheLock.lock()
        if let cached = embeddedSizeCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var embeddedSize: Int64? = nil
        let res = BoundedProcess.run("/usr/bin/unzip", ["-l", resolved.path], timeout: 6.0)
        if res.success {
            for line in res.output.split(whereSeparator: \.isNewline) {
                let cols = line.split(whereSeparator: \.isWhitespace)
                guard cols.count >= 4,
                      let pathCol = cols.last else { continue }
                let lower = pathCol.lowercased()
                if lower.hasPrefix("payload/") && (lower.hasSuffix(".app/romfs.img")) {
                    if let sz = Int64(cols[0]), sz > 0 {
                        embeddedSize = sz
                        break
                    }
                }
            }
        }

        cacheLock.lock()
        embeddedSizeCache[key] = embeddedSize
        cacheLock.unlock()
        return embeddedSize
    }

    /// Verifies that a local `romfs.img` file is non-empty, structurally intact (`DMROMFS1`),
    /// and matches `expected` byte size and header/index hash when provided.
    public static func verifyLocalImage(
        at url: URL,
        expected: RomfsExpectedIdentity?
    ) -> (valid: Bool, size: Int64, reason: String?) {
        let fm = FileManager.default
        let resolved = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else {
            return (false, 0, "arquivo ausente")
        }

        guard let key = cacheKey(for: resolved), key.size > 0 else {
            return (false, 0, "arquivo vazio (0 bytes)")
        }

        if let exp = expected, key.size != exp.expectedSize {
            let actualHuman = ByteCountFormatter.string(fromByteCount: key.size, countStyle: .file)
            let expectedHuman = ByteCountFormatter.string(fromByteCount: exp.expectedSize, countStyle: .file)
            return (false, key.size, "tamanho divergente (\(actualHuman) / \(key.size) bytes vs esperado \(expectedHuman) / \(exp.expectedSize) bytes)")
        }

        let digest = readOrComputeDigest(for: resolved, key: key)
        if !digest.isValidHeader {
            return (false, key.size, "cabeçalho DMROMFS1 corrompido ou arquivo truncado")
        }

        if let expIndex = expected?.expectedIndex,
           let actualIndex = digest.index,
           actualIndex != expIndex {
            let actualHex = String(format: "%016llx", actualIndex)
            let expHex = String(format: "%016llx", expIndex)
            return (false, key.size, "assinatura de índice RomFS divergente (\(actualHex) vs esperado \(expHex))")
        }

        return (true, key.size, nil)
    }

    /// Ranks patch directory names (`v262144` > `v65536` > `v0`) descending so newest extracted builds appear first.
    public static func parseBuildVersionRank(_ folderName: String) -> Int {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V"),
           let num = Int(trimmed.dropFirst()) {
            return num
        }
        return Int(trimmed) ?? -1
    }

    /// Generates NFC/NFD plus curly/straight apostrophe variants to match macOS APFS filenames reliably.
    public static func filenameVariants(of text: String) -> [String] {
        let forms = [
            text,
            text.precomposedStringWithCanonicalMapping,
            text.decomposedStringWithCanonicalMapping
        ]
        var seen = Set<String>()
        var result: [String] = []
        for form in forms {
            let variants = [
                form,
                form.replacingOccurrences(of: "’", with: "'"),
                form.replacingOccurrences(of: "'", with: "’")
            ]
            for v in variants where !v.isEmpty && !seen.contains(v) {
                seen.insert(v)
                result.append(v)
            }
        }
        return result
    }

    // MARK: - Internal Digest Computation

    private static func cacheKey(for resolvedURL: URL) -> CacheKey? {
        guard let vals = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              vals.isRegularFile == true,
              let fileSize = vals.fileSize else {
            return nil
        }
        let mtimeNs = Int64(((vals.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000_000_000.0).rounded())
        return CacheKey(path: resolvedURL.standardizedFileURL.path, size: Int64(fileSize), mtimeNs: mtimeNs)
    }

    private static func readOrComputeDigest(for resolvedURL: URL, key: CacheKey) -> ImageDigest {
        cacheLock.lock()
        if let cached = imageDigestCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let digest = computeDigest(at: resolvedURL, totalSize: key.size)

        cacheLock.lock()
        imageDigestCache[key] = digest
        cacheLock.unlock()
        return digest
    }

    /// Mirrors `romfs_id_of_image` (`dm/host/romfs_identity.h` / `RomfsIdentity.ofImage`).
    private static func computeDigest(at url: URL, totalSize: Int64) -> ImageDigest {
        guard totalSize >= 32, let handle = try? FileHandle(forReadingFrom: url) else {
            return ImageDigest(size: totalSize, index: nil, isValidHeader: totalSize > 0)
        }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: 32), head.count == 32 else {
            return ImageDigest(size: totalSize, index: nil, isValidHeader: false)
        }

        let headerBytes = [UInt8](head)
        // Only apply DMROMFS1 index bounds check when magic is DMROMFS1 (leaves non-packed raw images valid if unhashed).
        guard Array(headerBytes[0..<8]) == dmRomfsMagic else {
            return ImageDigest(size: totalSize, index: nil, isValidHeader: true)
        }

        func readUInt64LE(_ offset: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 {
                v |= UInt64(headerBytes[offset + i]) << (8 * UInt64(i))
            }
            return v
        }

        let total = UInt64(totalSize)
        let indexOffset = readUInt64LE(8)
        let indexSize = readUInt64LE(16)
        guard indexOffset >= 32, indexOffset <= total, indexSize == total - indexOffset else {
            return ImageDigest(size: totalSize, index: nil, isValidHeader: false)
        }

        var hash = mix(offsetBasis, headerBytes)
        do {
            try handle.seek(toOffset: indexOffset)
            var remaining = indexSize
            while remaining > 0 {
                let want = Int(min(remaining, UInt64(chunkBytes)))
                var piece = Data()
                piece.reserveCapacity(want)
                while piece.count < want {
                    guard let part = try handle.read(upToCount: want - piece.count), !part.isEmpty else {
                        return ImageDigest(size: totalSize, index: nil, isValidHeader: false)
                    }
                    piece.append(part)
                }
                hash = mix(hash, [UInt8](piece))
                remaining -= UInt64(want)
            }
        } catch {
            return ImageDigest(size: totalSize, index: nil, isValidHeader: false)
        }

        return ImageDigest(size: totalSize, index: hash, isValidHeader: true)
    }

    private static func mix(_ initialHash: UInt64, _ bytes: [UInt8]) -> UInt64 {
        var h = initialHash
        var i = 0
        while i < bytes.count {
            var word: UInt64 = 0
            let limit = min(8, bytes.count - i)
            for k in 0..<limit {
                word |= UInt64(bytes[i + k]) << (8 * UInt64(k))
            }
            h = (h ^ word) &* fnvPrime
            i += 8
        }
        return h
    }
}
