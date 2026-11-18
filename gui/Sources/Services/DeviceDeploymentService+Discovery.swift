import Foundation
import AppKit

// MARK: - Device and Installed Apps Discovery
extension DeviceDeploymentService {
    public func findBundleId(for titleId: String, gameName: String? = nil, on device: ConnectedAppleDevice) -> String? {
        guard device.isAvailable else { return nil }
        let (res, json) = BoundedProcess.runDevicectlJson(
            ["device", "info", "apps", "--device", device.id],
            timeout: 4.0
        )

        let tidLower = titleId.lowercased()
        let normTitle = Self.normalizeAppName(titleId)
        let normGame = gameName.map(Self.normalizeAppName) ?? ""

        if let resJson = json?["result"] as? [String: Any],
           let apps = resJson["apps"] as? [[String: Any]] {
            // 1. Match by Title ID in bundleIdentifier
            if !tidLower.isEmpty {
                for app in apps {
                    if let bid = app["bundleIdentifier"] as? String, bid.lowercased().contains(tidLower) {
                        return bid
                    }
                }
            }
            // 2. Match by normalized app display name
            for app in apps {
                guard let name = app["name"] as? String,
                      let bid = app["bundleIdentifier"] as? String else { continue }
                let normApp = Self.normalizeAppName(name)
                if !normApp.isEmpty && (normApp == normGame || normApp == normTitle || (!normGame.isEmpty && (normApp.contains(normGame) || normGame.contains(normApp)))) {
                    return bid
                }
            }
        }

        // Fallback table parser
        let out = res.output
        for line in out.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("Apps") || trimmed.hasPrefix("Name") || trimmed.hasPrefix("---") || trimmed.hasPrefix("{") { continue }
            let lower = trimmed.lowercased()
            let normLine = Self.normalizeAppName(trimmed)
            let matchesTitle = !tidLower.isEmpty && lower.contains(tidLower)
            let matchesName = !normGame.isEmpty && normLine.hasPrefix(normGame)
            if matchesTitle || matchesName {
                let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
                if let bundleToken = tokens.first(where: { $0.contains(".") && $0.contains(where: { $0.isLetter }) }) {
                    return String(bundleToken)
                }
            }
        }
        return nil
    }

    private static func normalizeAppName(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    public func revealInFinder(fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    internal func fetchConnectedDevices() -> [ConnectedAppleDevice] {
        let (res, json) = BoundedProcess.runDevicectlJson(
            ["list", "devices", "--timeout", "5"],
            timeout: 6.5
        )
        let raw = res.output

        guard let resDict = json?["result"] as? [String: Any],
              let list = resDict["devices"] as? [[String: Any]] else {
            return parseDeviceTable(raw)
        }

        var results: [ConnectedAppleDevice] = []
        for d in list {
            let devProps = (d["deviceProperties"] as? [String: Any]) ?? ((d["properties"] as? [String: Any])?["state"] as? [String: Any]) ?? [:]
            let hwProps = (d["hardwareProperties"] as? [String: Any]) ?? ((d["properties"] as? [String: Any])?["hardware"] as? [String: Any]) ?? [:]

            let name = (devProps["name"] as? String) ?? "iPhone"
            let udid = (hwProps["udid"] as? String) ?? (d["identifier"] as? String) ?? ""
            let model = (hwProps["marketingName"] as? String) ?? "Apple Device"

            var os = "iOS"
            if let osNum = devProps["osVersionNumber"] as? String {
                os = osNum
            } else if let osDict = devProps["osVersionNumber"] as? [String: Any], let s = osDict["stringValue"] as? String {
                os = s
            }

            guard !udid.isEmpty else { continue }

            let connState = ((d["connectionProperties"] as? [String: Any])?["tunnelState"] as? String) ?? (d["state"] as? String) ?? ""
            let isAvailable = !connState.lowercased().contains("unavailable") && !connState.lowercased().contains("offline")

            results.append(
                ConnectedAppleDevice(
                    id: udid,
                    name: name,
                    model: model,
                    osVersion: os,
                    isPaired: true,
                    isAvailable: isAvailable
                )
            )
        }

        return results.isEmpty ? parseDeviceTable(raw) : results
    }

    internal func parseDeviceTable(_ text: String) -> [ConnectedAppleDevice] {
        var devices: [ConnectedAppleDevice] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("Name") || trimmed.hasPrefix("---") { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 3 else { continue }
            let name = String(parts[0])
            var id = ""
            for p in parts {
                if p.count >= 16 && (p.contains("-") || p.allSatisfy({ $0.isHexDigit })) {
                    id = String(p).replacingOccurrences(of: "(UDID)", with: "")
                    break
                }
            }
            let isAvailable = !line.lowercased().contains("unavailable") && !line.lowercased().contains("offline")
            if !id.isEmpty {
                devices.append(ConnectedAppleDevice(id: id, name: name, model: "Apple Device", osVersion: "iOS", isPaired: true, isAvailable: isAvailable))
            }
        }
        return devices
    }

    // MARK: - Installed Apps Discovery & Auto-Sync
    public func syncInstalledApps(with games: [PortedGame], on device: ConnectedAppleDevice? = nil) {
        guard let dev = device ?? selectedDevice ?? connectedDevices.first, dev.isAvailable else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let apps = self.fetchInstalledAppsList(on: dev)
            if !apps.isEmpty {
                IosDeploymentTracker.shared.syncFromDeviceApps(
                    apps: apps,
                    libraryGames: games,
                    deviceName: dev.name,
                    deviceId: dev.id
                )
            }
        }
    }

    internal func fetchInstalledAppsList(on device: ConnectedAppleDevice) -> [[String: Any]] {
        guard device.isAvailable else { return [] }
        let (res, json) = BoundedProcess.runDevicectlJson(
            ["device", "info", "apps", "--device", device.id],
            timeout: 4.0
        )
        if res.success,
           let resDict = json?["result"] as? [String: Any],
           let apps = resDict["apps"] as? [[String: Any]] {
            return apps
        }
        return []
    }
}
