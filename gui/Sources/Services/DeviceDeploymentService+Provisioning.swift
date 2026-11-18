import Foundation
import AppKit

public struct ParsedProvisioningProfile {
    public let fileURL: URL
    public let name: String
    public let uuid: String
    public let teamIdentifier: String
    public let applicationIdentifier: String
    public let provisionedDevices: [String]
    public let expirationDate: Date
    public let entitlements: [String: Any]

    public var isExpired: Bool {
        return expirationDate < Date()
    }

    public var isWildcard: Bool {
        return applicationIdentifier.hasSuffix("*")
    }

    public var hasIncreasedMemoryLimit: Bool {
        return (entitlements["com.apple.developer.kernel.increased-memory-limit"] as? Bool) == true
    }

    public func provisions(deviceId: String) -> Bool {
        return provisionedDevices.contains(deviceId)
    }
}

// MARK: - Automated iOS Provisioning & Code Signing
extension DeviceDeploymentService {
    /// Runs a short-lived CLI helper (codesign, security, xattr) with a hard timeout and pipe draining.
    private func runBoundedSigningTool(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) -> (status: Int32, output: String) {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = pipe

        let outputLock = NSLock()
        var outputData = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            outputLock.lock()
            outputData.append(chunk)
            outputLock.unlock()
        }

        var timedOut = false
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + timeoutSeconds)
        watchdog.setEventHandler { [weak proc] in
            if let p = proc, p.isRunning {
                timedOut = true
                p.terminate()
            }
        }

        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            watchdog.cancel()
            return (-1, error.localizedDescription)
        }

        watchdog.resume()
        proc.waitUntilExit()
        watchdog.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil

        let trailing = pipe.fileHandleForReading.readDataToEndOfFile()
        outputLock.lock()
        if !trailing.isEmpty { outputData.append(trailing) }
        let finalText = String(data: outputData, encoding: .utf8) ?? ""
        outputLock.unlock()

        if timedOut {
            return (-2, "Command timed out after \(Int(timeoutSeconds))s: \(executable) \(finalText)")
        }
        return (proc.terminationStatus, finalText)
    }

    /// Scans standard Xcode and MobileDevice provisioning profile caches.
    internal func scanProvisioningProfiles() -> [ParsedProvisioningProfile] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let searchDirs = [
            "\(home)/Library/Developer/Xcode/UserData/Provisioning Profiles",
            "\(home)/Library/MobileDevice/Provisioning Profiles"
        ]

        var profiles: [ParsedProvisioningProfile] = []

        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".mobileprovision") {
                let fileURL = URL(fileURLWithPath: dir).appendingPathComponent(item)
                if let parsed = parseProvisioningProfile(at: fileURL) {
                    profiles.append(parsed)
                }
            }
        }
        return profiles
    }

    /// Decodes a CMS-signed .mobileprovision file into a structured ParsedProvisioningProfile.
    internal func parseProvisioningProfile(at fileURL: URL) -> ParsedProvisioningProfile? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["cms", "-D", "-i", fileURL.path]
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        let outputLock = NSLock()
        var data = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            outputLock.lock()
            data.append(chunk)
            outputLock.unlock()
        }

        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + 5.0)
        watchdog.setEventHandler { [weak proc] in
            if let p = proc, p.isRunning {
                p.terminate()
            }
        }

        guard (try? proc.run()) != nil else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        watchdog.resume()
        proc.waitUntilExit()
        watchdog.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil

        let trailing = pipe.fileHandleForReading.readDataToEndOfFile()
        outputLock.lock()
        if !trailing.isEmpty { data.append(trailing) }
        let rawData = data
        outputLock.unlock()

        guard proc.terminationStatus == 0 else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: rawData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let name = (plist["Name"] as? String) ?? fileURL.deletingPathExtension().lastPathComponent
        let uuid = (plist["UUID"] as? String) ?? ""
        let teamIds = (plist["TeamIdentifier"] as? [String]) ?? []
        let teamId = teamIds.first ?? ""
        let devices = (plist["ProvisionedDevices"] as? [String]) ?? []
        let expDate = (plist["ExpirationDate"] as? Date) ?? Date.distantPast
        let entitlements = (plist["Entitlements"] as? [String: Any]) ?? [:]
        let appId = (entitlements["application-identifier"] as? String) ?? ""

        return ParsedProvisioningProfile(
            fileURL: fileURL,
            name: name,
            uuid: uuid,
            teamIdentifier: teamId,
            applicationIdentifier: appId,
            provisionedDevices: devices,
            expirationDate: expDate,
            entitlements: entitlements
        )
    }

    /// Finds an existing, valid provisioning profile that authorizes the target device.
    internal func findMatchingProfile(
        for device: ConnectedAppleDevice,
        teamId: String?,
        titleId: String?,
        bundleIdHint: String? = nil,
        requireIncreasedMemory: Bool = true
    ) -> ParsedProvisioningProfile? {
        let profiles = scanProvisioningProfiles().filter { profile in
            !profile.isExpired && profile.provisions(deviceId: device.id)
        }

        // Strict team match whenever teamId is provided so profile & signing identity never mismatch.
        let teamProfiles: [ParsedProvisioningProfile]
        if let tid = teamId, !tid.isEmpty {
            teamProfiles = profiles.filter { $0.teamIdentifier == tid }
        } else {
            teamProfiles = profiles
        }

        let eligibleProfiles = requireIncreasedMemory
            ? teamProfiles.filter { $0.hasIncreasedMemoryLimit && !$0.isWildcard }
            : teamProfiles

        let sorted = eligibleProfiles.sorted { $0.expirationDate > $1.expirationDate }

        // Prefer exact bundle identifier match first (supports NxN Launcher Hub IPAs and custom IDs)
        if let hint = bundleIdHint?.lowercased(), !hint.isEmpty {
            if let exactBundle = sorted.first(where: { profile in
                guard !profile.isWildcard else { return false }
                let appIdLower = profile.applicationIdentifier.lowercased()
                return appIdLower == hint || appIdLower.hasSuffix(".\(hint)")
            }) {
                return exactBundle
            }
        }

        // Next prefer one explicitly tailored to the titleId (latest expiration first)
        if let tid = titleId?.lowercased(), !tid.isEmpty {
            if let exact = sorted.first(where: { !$0.isWildcard && $0.applicationIdentifier.lowercased().contains(tid) }) {
                return exact
            }
        }

        // Wildcard profiles cannot hold increased-memory-limit; allow only in non-entitled fallback mode.
        if !requireIncreasedMemory {
            if let wildcard = sorted.first(where: { $0.isWildcard }) {
                return wildcard
            }
        }

        // Never return an unrelated game's profile!
        // Returning another game's profile would cause iOS to treat this as an update to that other game and overwrite it.
        return nil
    }

    /// Creates a minimal, self-contained Xcode project that requests Automatic Signing + Increased Memory Limit.
    /// Using an isolated stub avoids relying on stale/absent DmIOS.xcodeproj or resource copy build phases.
    private func ensureProvisioningStubProject(withIncreasedMemory: Bool) -> URL? {
        let fm = FileManager.default
        let stubRoot = SystemDetector.shared.cachesDirectory
            .appendingPathComponent("provisioning_stub")
            .appendingPathComponent(withIncreasedMemory ? "entitled" : "basic")
        let xcodeprojURL = stubRoot.appendingPathComponent("ProvisioningStub.xcodeproj")
        let schemeDir = xcodeprojURL.appendingPathComponent("xcshareddata/xcschemes")

        do {
            try fm.createDirectory(at: schemeDir, withIntermediateDirectories: true)

            let mainM = "int main(int argc, char *argv[]) { (void)argc; (void)argv; return 0; }\n"
            try mainM.write(to: stubRoot.appendingPathComponent("main.m"), atomically: true, encoding: .utf8)

            let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleDevelopmentRegion</key>
                <string>en</string>
                <key>CFBundleExecutable</key>
                <string>$(EXECUTABLE_NAME)</string>
                <key>CFBundleIdentifier</key>
                <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
                <key>CFBundleInfoDictionaryVersion</key>
                <string>6.0</string>
                <key>CFBundleName</key>
                <string>$(PRODUCT_NAME)</string>
                <key>CFBundlePackageType</key>
                <string>APPL</string>
                <key>CFBundleShortVersionString</key>
                <string>1.0</string>
                <key>CFBundleVersion</key>
                <string>1</string>
                <key>LSRequiresIPhoneOS</key>
                <true/>
            </dict>
            </plist>
            """
            try infoPlist.write(to: stubRoot.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

            let entitlementsFileRef = withIncreasedMemory
                ? "\t\t222222222222222222220004 /* Stub.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Stub.entitlements; sourceTree = \"<group>\"; };\n"
                : ""
            let entitlementsGroupEntry = withIncreasedMemory
                ? "\t\t\t\t222222222222222222220004 /* Stub.entitlements */,\n"
                : ""
            let entitlementsBuildSetting = withIncreasedMemory
                ? "\t\t\t\tCODE_SIGN_ENTITLEMENTS = Stub.entitlements;\n"
                : ""

            if withIncreasedMemory {
                let entitlementsPlist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>com.apple.developer.kernel.increased-memory-limit</key>
                    <true/>
                </dict>
                </plist>
                """
                try entitlementsPlist.write(to: stubRoot.appendingPathComponent("Stub.entitlements"), atomically: true, encoding: .utf8)
            }

            let pbxproj = """
            // !$*UTF8*$!
            {
            	archiveVersion = 1;
            	classes = {
            	};
            	objectVersion = 54;
            	objects = {

            /* Begin PBXBuildFile section */
            		111111111111111111110001 /* main.m in Sources */ = {isa = PBXBuildFile; fileRef = 222222222222222222220002 /* main.m */; };
            /* End PBXBuildFile section */

            /* Begin PBXFileReference section */
            		222222222222222222220001 /* ProvisioningStub.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ProvisioningStub.app; sourceTree = BUILT_PRODUCTS_DIR; };
            		222222222222222222220002 /* main.m */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = main.m; sourceTree = "<group>"; };
            		222222222222222222220003 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
            \(entitlementsFileRef)/* End PBXFileReference section */

            /* Begin PBXFrameworksBuildPhase section */
            		333333333333333333330001 /* Frameworks */ = {
            			isa = PBXFrameworksBuildPhase;
            			buildActionMask = 2147483647;
            			files = (
            			);
            			runOnlyForDeploymentPostprocessing = 0;
            		};
            /* End PBXFrameworksBuildPhase section */

            /* Begin PBXGroup section */
            		444444444444444444440001 = {
            			isa = PBXGroup;
            			children = (
            				222222222222222222220002 /* main.m */,
            				222222222222222222220003 /* Info.plist */,
            \(entitlementsGroupEntry)\t\t\t\t444444444444444444440002 /* Products */,
            			);
            			sourceTree = "<group>";
            		};
            		444444444444444444440002 /* Products */ = {
            			isa = PBXGroup;
            			children = (
            				222222222222222222220001 /* ProvisioningStub.app */,
            			);
            			name = Products;
            			sourceTree = "<group>";
            		};
            /* End PBXGroup section */

            /* Begin PBXNativeTarget section */
            		555555555555555555550001 /* ProvisioningStub */ = {
            			isa = PBXNativeTarget;
            			buildConfigurationList = 888888888888888888880002 /* Build configuration list for PBXNativeTarget "ProvisioningStub" */;
            			buildPhases = (
            				666666666666666666660001 /* Sources */,
            				333333333333333333330001 /* Frameworks */,
            			);
            			buildRules = (
            			);
            			dependencies = (
            			);
            			name = ProvisioningStub;
            			productName = ProvisioningStub;
            			productReference = 222222222222222222220001 /* ProvisioningStub.app */;
            			productType = "com.apple.product-type.application";
            		};
            /* End PBXNativeTarget section */

            /* Begin PBXProject section */
            		777777777777777777770001 /* Project object */ = {
            			isa = PBXProject;
            			attributes = {
            				BuildIndependentTargetsInParallel = 1;
            				LastUpgradeCheck = 1600;
            			};
            			buildConfigurationList = 888888888888888888880001 /* Build configuration list for PBXProject "ProvisioningStub" */;
            			compatibilityVersion = "Xcode 14.0";
            			developmentRegion = en;
            			hasScannedForEncodings = 0;
            			knownRegions = (
            				en,
            				Base,
            			);
            			mainGroup = 444444444444444444440001;
            			productRefGroup = 444444444444444444440002 /* Products */;
            			projectDirPath = "";
            			projectRoot = "";
            			targets = (
            				555555555555555555550001 /* ProvisioningStub */,
            			);
            		};
            /* End PBXProject section */

            /* Begin PBXSourcesBuildPhase section */
            		666666666666666666660001 /* Sources */ = {
            			isa = PBXSourcesBuildPhase;
            			buildActionMask = 2147483647;
            			files = (
            				111111111111111111110001 /* main.m in Sources */,
            			);
            			runOnlyForDeploymentPostprocessing = 0;
            		};
            /* End PBXSourcesBuildPhase section */

            /* Begin XCBuildConfiguration section */
            		999999999999999999990001 /* Release */ = {
            			isa = XCBuildConfiguration;
            			buildSettings = {
            				ALWAYS_SEARCH_USER_PATHS = NO;
            				CLANG_ENABLE_OBJC_ARC = YES;
            				CODE_SIGN_IDENTITY = "iPhone Developer";
            				CODE_SIGN_STYLE = Automatic;
            				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
            				SDKROOT = iphoneos;
            				TARGETED_DEVICE_FAMILY = "1,2";
            			};
            			name = Release;
            		};
            		999999999999999999990002 /* Release */ = {
            			isa = XCBuildConfiguration;
            			buildSettings = {
            \(entitlementsBuildSetting)\t\t\t\tCODE_SIGN_IDENTITY = "iPhone Developer";
            				CODE_SIGN_STYLE = Automatic;
            				INFOPLIST_FILE = Info.plist;
            				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
            				PRODUCT_BUNDLE_IDENTIFIER = org.nxnative.provisioningstub;
            				PRODUCT_NAME = ProvisioningStub;
            				SDKROOT = iphoneos;
            				SUPPORTS_MACCATALYST = NO;
            				TARGETED_DEVICE_FAMILY = "1,2";
            			};
            			name = Release;
            		};
            /* End XCBuildConfiguration section */

            /* Begin XCConfigurationList section */
            		888888888888888888880001 /* Build configuration list for PBXProject "ProvisioningStub" */ = {
            			isa = XCConfigurationList;
            			buildConfigurations = (
            				999999999999999999990001 /* Release */,
            			);
            			defaultConfigurationIsVisible = 0;
            			defaultConfigurationName = Release;
            		};
            		888888888888888888880002 /* Build configuration list for PBXNativeTarget "ProvisioningStub" */ = {
            			isa = XCConfigurationList;
            			buildConfigurations = (
            				999999999999999999990002 /* Release */,
            			);
            			defaultConfigurationIsVisible = 0;
            			defaultConfigurationName = Release;
            		};
            /* End XCConfigurationList section */
            	};
            	rootObject = 777777777777777777770001 /* Project object */;
            }
            """
            try pbxproj.write(to: xcodeprojURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

            let scheme = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Scheme LastUpgradeVersion="1600" version="1.7">
               <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
                  <BuildActionEntries>
                     <BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="YES" buildForAnalyzing="NO">
                        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="555555555555555555550001" BuildableName="ProvisioningStub.app" BlueprintName="ProvisioningStub" ReferencedContainer="container:ProvisioningStub.xcodeproj"/>
                     </BuildActionEntry>
                  </BuildActionEntries>
               </BuildAction>
               <LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
               </LaunchAction>
            </Scheme>
            """
            try scheme.write(to: schemeDir.appendingPathComponent("ProvisioningStub.xcscheme"), atomically: true, encoding: .utf8)
            return xcodeprojURL
        } catch {
            return nil
        }
    }

    /// Triggers headless Xcode background provisioning with Apple Developer servers.
    internal func requestXcodeProvisioning(
        device: ConnectedAppleDevice,
        teamId: String,
        titleId: String,
        uniqueBundleId: String,
        requestIncreasedMemory: Bool = true
    ) -> ParsedProvisioningProfile? {
        guard let projectURL = ensureProvisioningStubProject(withIncreasedMemory: requestIncreasedMemory) else {
            return nil
        }
        let derivedDataURL = projectURL.deletingLastPathComponent().appendingPathComponent("dd")

        DispatchQueue.main.async {
            self.activeDeployment.statusMessage = L10n.t("settings_modal.auto_provisioning_status")
            self.activeDeployment.detailMessage = L10n.t("settings_modal.auto_provisioning_detail")
            let memNote = requestIncreasedMemory ? " (with Increased Memory Limit)" : " (standard entitlements fallback)"
            self.activeDeployment.logLines.append("==> Requesting official iOS provisioning profile\(memNote) for \(device.name)...")
            self.activeDeployment.logLines.append("==> Provisioning bundle identifier: \(uniqueBundleId)")
        }

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        proc.arguments = [
            "-project", projectURL.path,
            "-scheme", "ProvisioningStub",
            "-configuration", "Release",
            "-derivedDataPath", derivedDataURL.path,
            "-destination", "id=\(device.id)",
            "DEVELOPMENT_TEAM=\(teamId)",
            "PRODUCT_BUNDLE_IDENTIFIER=\(uniqueBundleId)",
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
            "build"
        ]
        proc.standardOutput = pipe
        proc.standardError = pipe

        let outputLock = NSLock()
        var outputData = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            outputLock.lock()
            outputData.append(chunk)
            outputLock.unlock()
        }

        do {
            try proc.run()
            // Xcode communicates with Apple Developer servers and creates/refreshes the profile within ~3-10 seconds.
            let startTime = Date()
            while proc.isRunning && Date().timeIntervalSince(startTime) < 35.0 {
                Thread.sleep(forTimeInterval: 0.8)
                if let found = self.findMatchingProfile(
                    for: device,
                    teamId: teamId,
                    titleId: titleId,
                    bundleIdHint: uniqueBundleId,
                    requireIncreasedMemory: requestIncreasedMemory
                ) {
                    DispatchQueue.main.async {
                        self.activeDeployment.logLines.append("[OK] Provisioning profile generated and received: \(found.name)")
                    }
                    proc.terminate()
                    proc.waitUntilExit()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    return found
                }
            }
            if proc.isRunning {
                proc.terminate()
            }
            proc.waitUntilExit()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        let trailing = pipe.fileHandleForReading.readDataToEndOfFile()
        outputLock.lock()
        if !trailing.isEmpty { outputData.append(trailing) }
        let rawLog = String(data: outputData, encoding: .utf8) ?? ""
        outputLock.unlock()

        if let found = findMatchingProfile(
            for: device,
            teamId: teamId,
            titleId: titleId,
            bundleIdHint: uniqueBundleId,
            requireIncreasedMemory: requestIncreasedMemory
        ) {
            DispatchQueue.main.async {
                self.activeDeployment.logLines.append("[OK] Provisioning profile generated and received: \(found.name)")
            }
            return found
        }

        let summaryLines = rawLog
            .components(separatedBy: .newlines)
            .filter { $0.contains("error:") || $0.contains("Provisioning") || $0.contains("entitlement") || $0.contains("Failed") }
            .suffix(4)
            .joined(separator: " | ")
        if !summaryLines.isEmpty {
            DispatchQueue.main.async {
                self.activeDeployment.logLines.append("[WARN] Provisioning attempt exited (\(proc.terminationStatus)): \(summaryLines)")
            }
        }
        return nil
    }

    /// Removes AppleDouble (._*), .DS_Store, xattrs, and stale _CodeSignature seals inside an extracted .app bundle.
    private func cleanAppleMetadataAndStaleSignatures(in appURL: URL) {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(
            at: appURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: nil
        ) {
            var toRemove: [URL] = []
            for case let itemURL as URL in enumerator {
                let name = itemURL.lastPathComponent
                if name.hasPrefix("._") || name == ".DS_Store" || name == "_CodeSignature" {
                    toRemove.append(itemURL)
                }
            }
            for itemURL in toRemove {
                try? fm.removeItem(at: itemURL)
            }
        }

        _ = runBoundedSigningTool(
            executable: "/usr/bin/xattr",
            arguments: ["-cr", appURL.path],
            timeoutSeconds: 10.0
        )
    }

    /// Extracts the 16-hex character Nintendo Switch Title ID from the bundle or path.
    internal func extractTitleId(from appURL: URL) -> String? {
        if let bid = extractBundleIdentifier(from: appURL) {
            let tokens = bid.components(separatedBy: ".")
            for token in tokens {
                if token.count == 16 && token.allSatisfy({ $0.isHexDigit }) {
                    return token.uppercased()
                }
            }
        }

        let path = appURL.path
        let regex = try? NSRegularExpression(pattern: "(0[14]00[0-9A-Fa-f]{12})", options: [])
        if let match = regex?.firstMatch(in: path, options: [], range: NSRange(location: 0, length: path.utf16.count)),
           let range = Range(match.range(at: 1), in: path) {
            return String(path[range]).uppercased()
        }
        return nil
    }

    /// Handles automated profile acquisition, bundle ID alignment, entitlements embedding, and code signing.
    @discardableResult
    internal func applyCodeSignatureAndProvisioning(
        targetAppURL: URL,
        device: ConnectedAppleDevice,
        team: DeveloperSigningTeam?
    ) -> (Bool, String?) {
        var chosenTeam = team ?? selectedSigningTeam ?? signingTeams.first
        if chosenTeam == nil {
            let discovered = fetchSigningIdentities()
            DispatchQueue.main.async {
                if self.signingTeams.isEmpty {
                    self.signingTeams = discovered
                }
                if self.selectedSigningTeam == nil {
                    self.selectedSigningTeam = discovered.first
                }
            }
            chosenTeam = discovered.first
        }

        let fm = FileManager.default
        let extractedTitleId = extractTitleId(from: targetAppURL)
        let titleId = extractedTitleId ?? "0100000000000000"
        let userName = NSUserName().lowercased().filter { $0.isLetter || $0.isNumber }
        let userPrefix = userName.isEmpty ? "developer" : userName
        let currentBundleId = extractBundleIdentifier(from: targetAppURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetBundleId: String
        if let tid = extractedTitleId {
            targetBundleId = "com.\(userPrefix).nxnative.\(tid.lowercased())"
        } else if currentBundleId.lowercased() == "org.nxnative.launcher" || currentBundleId.lowercased() == "org.nxnative.shell" {
            targetBundleId = NxHubDeploymentService.hubBundleId
        } else if !currentBundleId.isEmpty {
            targetBundleId = currentBundleId
        } else {
            targetBundleId = "com.\(userPrefix).nxnative.\(titleId.lowercased())"
        }
        let profileTitleIdHint = extractedTitleId

        // 1. Check custom user profile override
        var activeProfileURL: URL? = nil
        let customProfilePath = UserDefaults.standard.string(forKey: "NXNative_SavedCustomProvisioningProfilePath")
        if let provPath = customProfilePath, !provPath.isEmpty, fm.fileExists(atPath: provPath) {
            activeProfileURL = URL(fileURLWithPath: provPath)
            DispatchQueue.main.async {
                self.activeDeployment.logLines.append("==> Using custom provisioning profile: \(activeProfileURL!.lastPathComponent)")
            }
        }

        // 2. Validate signing identity / team before profile provisioning
        let teamId = chosenTeam?.id ?? ""
        if activeProfileURL == nil {
            guard let validTeam = chosenTeam, !validTeam.id.isEmpty, validTeam.hasCertificateInKeychain else {
                return (
                    false,
                    "Nenhum certificado iOS válido encontrado no Keychain. Faça login com sua conta Apple no Xcode (Settings > Accounts) e selecione um Signing Team."
                )
            }
        }

        // 3. Search existing profile with Increased Memory Limit entitlement first
        if activeProfileURL == nil {
            if let matched = findMatchingProfile(
                for: device,
                teamId: teamId,
                titleId: profileTitleIdHint,
                bundleIdHint: targetBundleId,
                requireIncreasedMemory: true
            ) {
                activeProfileURL = matched.fileURL
                DispatchQueue.main.async {
                    self.activeDeployment.logLines.append("[OK] Matched existing high-memory provisioning profile for \(device.name): \(matched.name)")
                }
            }
        }

        // 4. Auto-generate profile via ProvisioningStub with Increased Memory Limit if missing
        if activeProfileURL == nil {
            if let generated = requestXcodeProvisioning(
                device: device,
                teamId: teamId,
                titleId: titleId,
                uniqueBundleId: targetBundleId,
                requestIncreasedMemory: true
            ) {
                activeProfileURL = generated.fileURL
            } else {
                DispatchQueue.main.async {
                    self.activeDeployment.logLines.append("[WARN] Could not provision Increased Memory Limit profile; checking standard fallback profile...")
                }
                if let fallbackMatched = findMatchingProfile(
                    for: device,
                    teamId: teamId,
                    titleId: profileTitleIdHint,
                    bundleIdHint: targetBundleId,
                    requireIncreasedMemory: false
                ) {
                    activeProfileURL = fallbackMatched.fileURL
                    DispatchQueue.main.async {
                        self.activeDeployment.logLines.append("[WARN] Using fallback profile without Increased Memory Limit: \(fallbackMatched.name)")
                    }
                } else if let fallbackGenerated = requestXcodeProvisioning(
                    device: device,
                    teamId: teamId,
                    titleId: titleId,
                    uniqueBundleId: targetBundleId,
                    requestIncreasedMemory: false
                ) {
                    activeProfileURL = fallbackGenerated.fileURL
                }
            }
        }

        guard let profileURL = activeProfileURL else {
            return (
                false,
                "Não foi possível obter um perfil de provisionamento iOS para \(device.name) (Title ID: \(titleId)). Verifique se o dispositivo está conectado e se sua conta Apple está autenticada no Xcode."
            )
        }

        // 5. Inject embedded.mobileprovision and align CFBundleIdentifier & Entitlements
        cleanAppleMetadataAndStaleSignatures(in: targetAppURL)

        var tempEntitlementsURL: URL? = nil
        let dest = targetAppURL.appendingPathComponent("embedded.mobileprovision")
        do {
            try fm.copyItem(at: profileURL, to: dest)
        } catch {
            return (false, "Falha ao embutir embedded.mobileprovision: \(error.localizedDescription)")
        }

        if let parsed = parseProvisioningProfile(at: profileURL) {
            if parsed.hasIncreasedMemoryLimit {
                DispatchQueue.main.async {
                    self.activeDeployment.logLines.append("[OK] Provisioning profile grants com.apple.developer.kernel.increased-memory-limit.")
                }
            } else {
                DispatchQueue.main.async {
                    self.activeDeployment.logLines.append("[WARN] Provisioning profile does NOT include com.apple.developer.kernel.increased-memory-limit; large games may hit iOS memory limits.")
                }
            }

            let appId = parsed.applicationIdentifier
            var alignedBundleId = appId
            if let dotIdx = appId.firstIndex(of: ".") {
                alignedBundleId = String(appId[appId.index(after: dotIdx)...])
            }

            if !alignedBundleId.isEmpty && !alignedBundleId.contains("*") {
                let infoPlistURL = targetAppURL.appendingPathComponent("Info.plist")
                if var infoDict = try? PropertyListSerialization.propertyList(from: Data(contentsOf: infoPlistURL), options: .mutableContainers, format: nil) as? [String: Any] {
                    infoDict["CFBundleIdentifier"] = alignedBundleId
                    if let updatedData = try? PropertyListSerialization.data(fromPropertyList: infoDict, format: .xml, options: 0) {
                        try? updatedData.write(to: infoPlistURL)
                        DispatchQueue.main.async {
                            self.activeDeployment.logLines.append("==> Aligned bundle identifier: \(alignedBundleId)")
                        }
                    }
                }
            }

            var signingEntitlements = parsed.entitlements
            if !signingEntitlements.isEmpty {
                if appId.contains("*"),
                   !parsed.teamIdentifier.isEmpty,
                   let currentBid = extractBundleIdentifier(from: targetAppURL),
                   !currentBid.isEmpty {
                    signingEntitlements["application-identifier"] = "\(parsed.teamIdentifier).\(currentBid)"
                }

                let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nxnative_entitlements_\(UUID().uuidString).plist")
                if let entData = try? PropertyListSerialization.data(fromPropertyList: signingEntitlements, format: .xml, options: 0) {
                    try? entData.write(to: tmpURL)
                    tempEntitlementsURL = tmpURL
                }
            }
        }

        // 6. Determine signing identity
        let signingId = chosenTeam?.signingIdentity ?? (chosenTeam?.name.contains(":") == true ? chosenTeam?.name : nil)
        let resolvedIdentity: String
        if let activeTeam = chosenTeam, activeTeam.hasCertificateInKeychain, let validIdentity = signingId {
            resolvedIdentity = validIdentity
            DispatchQueue.main.async {
                self.activeDeployment.logLines.append("==> Signing with development identity: \(validIdentity)")
            }
        } else if let activeTeam = chosenTeam, activeTeam.hasCertificateInKeychain {
            resolvedIdentity = activeTeam.name
            DispatchQueue.main.async {
                self.activeDeployment.logLines.append("==> Signing with identity: \(activeTeam.name)")
            }
        } else {
            if let entURL = tempEntitlementsURL {
                try? fm.removeItem(at: entURL)
            }
            return (
                false,
                "Perfil de provisionamento encontrado, mas não há identidade Apple Development correspondente no Keychain para assinar o app."
            )
        }

        // 7. Sign embedded frameworks first if present (without entitlements)
        let frameworksDir = targetAppURL.appendingPathComponent("Frameworks")
        if let fwItems = try? fm.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil) {
            for fw in fwItems where fw.pathExtension == "framework" || fw.pathExtension == "dylib" {
                let fwRes = runBoundedSigningTool(
                    executable: "/usr/bin/codesign",
                    arguments: ["--force", "--sign", resolvedIdentity, fw.path],
                    timeoutSeconds: 15.0
                )
                if fwRes.status != 0 {
                    if let entURL = tempEntitlementsURL {
                        try? fm.removeItem(at: entURL)
                    }
                    let trimmed = fwRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (false, "Falha ao assinar framework \(fw.lastPathComponent): \(trimmed)")
                }
            }
        }

        // 8. Run fast bundle signature without --deep to avoid hashing gigabytes of RomFS
        var signArgs = ["--force"]
        if let entURL = tempEntitlementsURL {
            signArgs.append(contentsOf: ["--entitlements", entURL.path])
        }
        signArgs.append(contentsOf: ["--sign", resolvedIdentity, targetAppURL.path])

        let signRes = runBoundedSigningTool(
            executable: "/usr/bin/codesign",
            arguments: signArgs,
            timeoutSeconds: 30.0
        )

        if let entURL = tempEntitlementsURL {
            try? fm.removeItem(at: entURL)
        }

        guard signRes.status == 0 else {
            let trimmed = signRes.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, "codesign falhou ao assinar \(targetAppURL.lastPathComponent): \(trimmed)")
        }

        DispatchQueue.main.async {
            self.activeDeployment.logLines.append("[OK] Code signature applied successfully.")
        }
        return (true, nil)
    }
}
