import Foundation

public enum MouseInputMode: String, Codable, CaseIterable {
    case auto = "auto"
    case rightStick = "rightStick"
    case nativeSwitch2 = "nativeSwitch2"
    case touchscreen = "touchscreen"
}

public struct ControllerProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var isDefault: Bool
    public var targetDeviceName: String
    public var gamepadBindings: [String: SwitchButton]
    public var keyboardBindings: [UInt16: SwitchButton]
    public var keyboardMovement: [String: UInt16]
    public var analogDeadzone: Double
    public var mouseMode: MouseInputMode
    public var mouseAsRightStick: Bool
    public var mouseSensitivity: Double
    public var mouseInvertX: Bool
    public var mouseInvertY: Bool
    public var mouseRightStickMode: String
    public var mouseSwitch2Enabled: Bool
    public var mouseSwitch2PointerSpeed: Double
    public var mouseSwitch2LockCursor: Bool
    public var mouseSwitch2PrimaryButton: String
    public var mouseSwitch2Side: String
    public var mouseSwitch2InvertY: Bool
    public var enableRumble: Bool
    public var rumbleStrength: Double
    public var rumbleFloorBoost: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        isDefault: Bool = false,
        targetDeviceName: String = "All Gamepads",
        gamepadBindings: [String: SwitchButton],
        keyboardBindings: [UInt16: SwitchButton],
        keyboardMovement: [String: UInt16] = ["up": 13, "left": 0, "down": 1, "right": 2],
        analogDeadzone: Double = 0.10,
        mouseMode: MouseInputMode = .auto,
        mouseAsRightStick: Bool = true,
        mouseSensitivity: Double = 5.0,
        mouseInvertX: Bool = false,
        mouseInvertY: Bool = false,
        mouseRightStickMode: String = "cursorLock",
        mouseSwitch2Enabled: Bool = true,
        mouseSwitch2PointerSpeed: Double = 1.0,
        mouseSwitch2LockCursor: Bool = true,
        mouseSwitch2PrimaryButton: String = "left",
        mouseSwitch2Side: String = "right",
        mouseSwitch2InvertY: Bool = false,
        enableRumble: Bool = true,
        rumbleStrength: Double = 1.0,
        rumbleFloorBoost: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.targetDeviceName = targetDeviceName
        self.gamepadBindings = gamepadBindings
        self.keyboardBindings = keyboardBindings
        self.keyboardMovement = keyboardMovement
        self.analogDeadzone = analogDeadzone
        self.mouseMode = mouseMode
        self.mouseAsRightStick = mouseAsRightStick
        self.mouseSensitivity = mouseSensitivity
        self.mouseInvertX = mouseInvertX
        self.mouseInvertY = mouseInvertY
        self.mouseRightStickMode = mouseRightStickMode
        self.mouseSwitch2Enabled = mouseSwitch2Enabled
        self.mouseSwitch2PointerSpeed = mouseSwitch2PointerSpeed
        self.mouseSwitch2LockCursor = mouseSwitch2LockCursor
        self.mouseSwitch2PrimaryButton = mouseSwitch2PrimaryButton
        self.mouseSwitch2Side = mouseSwitch2Side
        self.mouseSwitch2InvertY = mouseSwitch2InvertY
        self.enableRumble = enableRumble
        self.rumbleStrength = rumbleStrength
        self.rumbleFloorBoost = rumbleFloorBoost
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isDefault, targetDeviceName, gamepadBindings, keyboardBindings, keyboardMovement, analogDeadzone
        case mouseMode, mouseAsRightStick, mouseSensitivity, mouseInvertX, mouseInvertY, mouseRightStickMode
        case mouseSwitch2Enabled, mouseSwitch2PointerSpeed, mouseSwitch2LockCursor
        case mouseSwitch2PrimaryButton, mouseSwitch2Side, mouseSwitch2InvertY
        case enableRumble, rumbleStrength, rumbleFloorBoost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.isDefault = try container.decode(Bool.self, forKey: .isDefault)
        self.targetDeviceName = try container.decode(String.self, forKey: .targetDeviceName)
        self.gamepadBindings = try container.decode([String: SwitchButton].self, forKey: .gamepadBindings)
        self.keyboardBindings = try container.decode([UInt16: SwitchButton].self, forKey: .keyboardBindings)
        self.keyboardMovement = try container.decodeIfPresent([String: UInt16].self, forKey: .keyboardMovement) ?? ["up": 13, "left": 0, "down": 1, "right": 2]
        self.analogDeadzone = try container.decodeIfPresent(Double.self, forKey: .analogDeadzone) ?? 0.10
        let decodedLegacyStick = try container.decodeIfPresent(Bool.self, forKey: .mouseAsRightStick) ?? true
        let decodedMode = try container.decodeIfPresent(MouseInputMode.self, forKey: .mouseMode)
        self.mouseMode = decodedMode ?? (decodedLegacyStick ? .auto : .touchscreen)
        self.mouseAsRightStick = (self.mouseMode == .rightStick || self.mouseMode == .auto)
        self.mouseSensitivity = try container.decodeIfPresent(Double.self, forKey: .mouseSensitivity) ?? 5.0
        self.mouseInvertX = try container.decodeIfPresent(Bool.self, forKey: .mouseInvertX) ?? false
        self.mouseInvertY = try container.decodeIfPresent(Bool.self, forKey: .mouseInvertY) ?? false
        self.mouseRightStickMode = try container.decodeIfPresent(String.self, forKey: .mouseRightStickMode) ?? "cursorLock"
        self.mouseSwitch2Enabled = try container.decodeIfPresent(Bool.self, forKey: .mouseSwitch2Enabled) ?? true
        self.mouseSwitch2PointerSpeed = try container.decodeIfPresent(Double.self, forKey: .mouseSwitch2PointerSpeed) ?? 1.0
        self.mouseSwitch2LockCursor = try container.decodeIfPresent(Bool.self, forKey: .mouseSwitch2LockCursor) ?? true
        self.mouseSwitch2PrimaryButton = try container.decodeIfPresent(String.self, forKey: .mouseSwitch2PrimaryButton) ?? "left"
        self.mouseSwitch2Side = try container.decodeIfPresent(String.self, forKey: .mouseSwitch2Side) ?? "right"
        self.mouseSwitch2InvertY = try container.decodeIfPresent(Bool.self, forKey: .mouseSwitch2InvertY) ?? false
        self.enableRumble = try container.decodeIfPresent(Bool.self, forKey: .enableRumble) ?? true
        self.rumbleStrength = try container.decodeIfPresent(Double.self, forKey: .rumbleStrength) ?? 1.0
        self.rumbleFloorBoost = try container.decodeIfPresent(Bool.self, forKey: .rumbleFloorBoost) ?? true
    }

    // MARK: - Factory Presets

    public static var nintendoDefault: ControllerProfile {
        var gp: [String: SwitchButton] = [:]
        for btn in SwitchButton.allCases {
            gp[btn.defaultGamepadElement] = btn
        }

        var kb: [UInt16: SwitchButton] = [:]
        for btn in SwitchButton.allCases {
            kb[btn.defaultKeyCode] = btn
        }

        return ControllerProfile(
            name: "Nintendo Switch (Default)",
            isDefault: true,
            targetDeviceName: "Nintendo Switch Pro Controller",
            gamepadBindings: gp,
            keyboardBindings: kb
        )
    }

    public static var xboxLayout: ControllerProfile {
        var p = ControllerProfile.nintendoDefault
        p.id = UUID()
        p.name = "Xbox / PC Controller"
        p.isDefault = false
        p.targetDeviceName = "Xbox Wireless Controller"
        // On Xbox: Physical A (South) is Confirm/A in games, Physical B (East) is Cancel/B
        // Physical X (West) is Y, Physical Y (North) is X
        p.gamepadBindings["buttonA"] = .a
        p.gamepadBindings["buttonB"] = .b
        p.gamepadBindings["buttonX"] = .y
        p.gamepadBindings["buttonY"] = .x
        return p
    }

    public static var playstationLayout: ControllerProfile {
        var p = ControllerProfile.nintendoDefault
        p.id = UUID()
        p.name = "PlayStation DualSense"
        p.isDefault = false
        p.targetDeviceName = "DualSense / DualShock 4"
        p.gamepadBindings["buttonA"] = .b // Cross -> B (Standard Switch Confirm or Japanese)
        p.gamepadBindings["buttonB"] = .a // Circle -> A
        p.gamepadBindings["buttonX"] = .y // Square -> Y
        p.gamepadBindings["buttonY"] = .x // Triangle -> X
        return p
    }

    // MARK: - Quick Face Swap (Enhancement 2: Nintendo <-> Xbox/PC layout)

    public mutating func swapFaceButtons() {
        let oldA = gamepadBindings["buttonB"]
        let oldB = gamepadBindings["buttonA"]
        let oldX = gamepadBindings["buttonY"]
        let oldY = gamepadBindings["buttonX"]

        gamepadBindings["buttonB"] = oldB
        gamepadBindings["buttonA"] = oldA
        gamepadBindings["buttonY"] = oldY
        gamepadBindings["buttonX"] = oldX
    }

    // MARK: - Export for Ported Games (input_mapping.json)

    public func exportDictionary() -> [String: Any] {
        var gpExport: [String: String] = [:]
        for (k, v) in gamepadBindings {
            gpExport[k] = v.rawValue
        }

        var kbExport: [String: String] = [:]
        for (k, v) in keyboardBindings {
            kbExport[String(k)] = v.rawValue
        }

        var movExport: [String: Int] = [:]
        for (k, v) in keyboardMovement {
            movExport[k] = Int(v)
        }

        return [
            "name": name,
            "analogDeadzone": analogDeadzone,
            "mouseMode": mouseMode.rawValue,
            "mouseAsRightStick": (mouseMode == .rightStick || mouseMode == .auto),
            "mouseSensitivity": mouseSensitivity,
            "mouseInvertX": mouseInvertX,
            "mouseInvertY": mouseInvertY,
            "mouseRightStickMode": mouseRightStickMode,
            "mouseSwitch2Enabled": mouseSwitch2Enabled,
            "mouseSwitch2PointerSpeed": mouseSwitch2PointerSpeed,
            "mouseSwitch2LockCursor": mouseSwitch2LockCursor,
            "mouseSwitch2PrimaryButton": mouseSwitch2PrimaryButton,
            "mouseSwitch2Side": mouseSwitch2Side,
            "mouseSwitch2InvertY": mouseSwitch2InvertY,
            "enableRumble": enableRumble,
            "rumbleStrength": rumbleStrength,
            "rumbleFloorBoost": rumbleFloorBoost,
            "gamepad": gpExport,
            "keyboard": kbExport,
            "keyboardMovement": movExport
        ]
    }
}
