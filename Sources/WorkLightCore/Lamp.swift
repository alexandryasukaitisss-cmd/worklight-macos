import Foundation

public enum LampError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case credential
    case connection
    case denied
    case response
    case unavailable
    case unconfirmed
    case invalidPreset

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Configure Home Assistant in Settings…"
        case .credential: "Missing or invalid Home Assistant access token"
        case .connection: "Unable to reach Home Assistant"
        case .denied: "Home Assistant rejected the access token"
        case .response: "Unexpected response from Home Assistant"
        case .unavailable: "Light entity is unavailable"
        case .unconfirmed: "Light did not confirm the state change"
        case .invalidPreset: "Invalid light preset configuration"
        }
    }
}

public struct RGB: Equatable, Sendable {
    public let packed: Int

    public init?(packed: Int) {
        guard (1...0xFFFFFF).contains(packed) else { return nil }
        self.packed = packed
    }

    public init?(channels: [Int]) {
        guard channels.count == 3, channels.allSatisfy({ (0...255).contains($0) }) else { return nil }
        self.init(packed: channels[0] << 16 | channels[1] << 8 | channels[2])
    }

    public var channels: [Int] { [packed >> 16, packed >> 8 & 255, packed & 255] }

    public static let red = RGB(packed: 0xE61903)!
    public static let green = RGB(packed: 0x00CC00)!
    public static let violet = RGB(packed: 0x9271EC)!

    public func matches(_ other: RGB) -> Bool {
        zip(channels, other.channels).allSatisfy { abs($0 - $1) <= 4 }
    }
}

public enum LampOutput: Equatable, Sendable {
    case off
    case color(RGB, brightness: Int)
    case white(kelvin: Int, brightness: Int)

    public var brightness: Int? {
        switch self {
        case .off: nil
        case let .color(_, brightness), let .white(_, brightness): brightness
        }
    }

    public var isValid: Bool {
        switch self {
        case .off: true
        case let .color(_, brightness): LampSettings.brightnessRange.contains(brightness)
        case let .white(kelvin, brightness):
            LampSettings.kelvinRange.contains(kelvin) && LampSettings.brightnessRange.contains(brightness)
        }
    }

    public func matches(_ other: LampOutput) -> Bool {
        switch (self, other) {
        case (.off, .off): true
        case let (.color(a, x), .color(b, y)): a.matches(b) && abs(x - y) <= 2
        case let (.white(a, x), .white(b, y)): abs(a - b) <= 35 && abs(x - y) <= 2
        default: false
        }
    }
}

public enum LampScene: String, CaseIterable, Codable, Sendable {
    case busy, free, normal, off

    public var title: String {
        switch self {
        case .busy: "Busy (On Air)"
        case .free: "Available"
        case .normal: "Normal Light"
        case .off: "Off"
        }
    }
}

public enum CallReturnBehavior: String, CaseIterable, Codable, Sendable {
    case previous
    case free
    case normal
    case off

    public var title: String {
        switch self {
        case .previous: "Restore previous state"
        case .free: "Switch to Available (Green)"
        case .normal: "Switch to Normal Light"
        case .off: "Turn Off"
        }
    }
}

public struct HomeAssistantEndpoint: Codable, Equatable, Sendable {
    public var baseURLString: String
    public var entityID: String
    public var useMiotEffects: Bool

    public init(
        baseURLString: String = "http://homeassistant.local:8123",
        entityID: String = "",
        useMiotEffects: Bool = false
    ) {
        self.baseURLString = baseURLString
        self.entityID = entityID
        self.useMiotEffects = useMiotEffects
    }

    public var normalizedBaseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            return nil
        }
        return url
    }

    public var normalizedEntityID: String? {
        let trimmed = entityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("light."), trimmed.count > 6, trimmed.count <= 128 else { return nil }
        let suffix = trimmed.dropFirst(6)
        guard suffix.unicodeScalars.allSatisfy({ scalar in
            (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || scalar.value == 95
        }) else {
            return nil
        }
        return trimmed
    }

    public var isConfigured: Bool {
        normalizedBaseURL != nil && normalizedEntityID != nil
    }
}

public struct LampSettings: Codable, Equatable, Sendable {
    public enum NormalStyle: String, CaseIterable, Codable, Sendable { case white, color }

    public var endpoint = HomeAssistantEndpoint()
    public var busyBrightness = 45
    public var freeBrightness = 40
    public var normalBrightness = 75
    public var normalStyle = NormalStyle.white
    public var kelvin = 2700
    public var normalRGB = RGB.violet.packed
    public var autoBusyOnMicrophone = false
    public var callReturnBehavior = CallReturnBehavior.previous

    public init() {}

    public static let defaults = LampSettings()
    public static let brightnessRange = 1...100
    public static let kelvinRange = 1700...6500

    public var isValid: Bool {
        [busyBrightness, freeBrightness, normalBrightness].allSatisfy(Self.brightnessRange.contains)
            && Self.kelvinRange.contains(kelvin)
            && RGB(packed: normalRGB) != nil
    }

    public static func read(_ data: Data?) -> LampSettings {
        guard let data, data.count <= 8192,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.isValid else {
            return .defaults
        }
        return value
    }

    public func output(for scene: LampScene) -> LampOutput {
        switch scene {
        case .busy: .color(.red, brightness: busyBrightness)
        case .free: .color(.green, brightness: freeBrightness)
        case .normal:
            normalStyle == .color
                ? .color(RGB(packed: normalRGB) ?? .violet, brightness: normalBrightness)
                : .white(kelvin: kelvin, brightness: normalBrightness)
        case .off: .off
        }
    }

    public func scene(for output: LampOutput) -> LampScene {
        if output.matches(self.output(for: .normal)) { return .normal }
        switch output {
        case .off: return .off
        case .white: return .normal
        case let .color(rgb, _):
            let c = rgb.channels
            if c[0] > 2 * max(c[1], c[2]) { return .busy }
            if c[1] > 2 * max(c[0], c[2]) { return .free }
            return .normal
        }
    }
}

public struct LampReport: Decodable, Sendable {
    public struct Attributes: Decodable, Sendable {
        public let brightness: Double?
        public let effect: String?
        public let colorMode: String?
        public let rgb: [Int]?
        public let kelvin: Int?
        public let deviceMode: Int?
        public let deviceRGB: Int?
        public let deviceKelvin: Int?
        public let deviceBrightness: Int?

        enum CodingKeys: String, CodingKey {
            case brightness, effect
            case colorMode = "color_mode", rgb = "rgb_color", kelvin = "color_temp_kelvin"
            case deviceMode = "light.mode", deviceRGB = "light.color"
            case deviceKelvin = "light.color_temperature", deviceBrightness = "light.brightness"
        }
    }

    public let entityID: String
    public let state: String
    public let revision: String
    public let attributes: Attributes

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id", state, attributes, revision = "last_updated"
    }

    public var brightness: Int? {
        guard let value = attributes.brightness, (1...255).contains(value) else { return nil }
        return max(1, Int((value * 100 / 255).rounded()))
    }

    public var output: LampOutput? {
        if state == "off" { return .off }
        guard state == "on", let brightness else { return nil }
        let a = attributes

        if a.effect == "Day" || (a.effect != "Color" && a.colorMode == "color_temp") {
            let k = a.colorMode == "color_temp" ? a.kelvin
                : (a.deviceMode == 2 && a.deviceBrightness == brightness ? a.deviceKelvin : nil)
            if let k, LampSettings.kelvinRange.contains(k) {
                return .white(kelvin: k, brightness: brightness)
            }
        }

        let isColorMode = a.colorMode == "rgb" || a.colorMode == "rgbw" || a.colorMode == "rgbww" || a.colorMode == "hs" || a.colorMode == "xy"
        if a.effect == "Color" || (a.effect != "Day" && isColorMode) {
            let rgb = isColorMode ? a.rgb.flatMap(RGB.init(channels:))
                : (a.deviceMode == 1 && a.deviceBrightness == brightness ? a.deviceRGB.flatMap(RGB.init(packed:)) : nil)
            if let rgb {
                return .color(rgb, brightness: brightness)
            }
        }

        if a.colorMode == "brightness" || a.colorMode == "onoff" {
            return .white(kelvin: 2700, brightness: brightness)
        }
        return nil
    }

    public func acknowledges(_ requested: LampOutput, miotEffects: Bool = false) -> Bool {
        if case .off = requested { return state == "off" }
        guard state == "on", let brightness, let requestedBrightness = requested.brightness,
              abs(brightness - requestedBrightness) <= 2 else {
            return false
        }
        switch requested {
        case .off:
            return false
        case let .color(rgb, _):
            if miotEffects {
                guard attributes.effect == "Color" else { return false }
                if attributes.colorMode == "color_temp" { return true }
            }
            let isColorMode = attributes.colorMode == "rgb" || attributes.colorMode == "rgbw"
                || attributes.colorMode == "rgbww" || attributes.colorMode == "hs" || attributes.colorMode == "xy"
            guard isColorMode else { return false }
            return attributes.rgb.flatMap(RGB.init(channels:)).map(rgb.matches) == true
        case let .white(kelvin, _):
            if miotEffects {
                guard attributes.effect == "Day" else { return false }
                if attributes.colorMode == "rgb" { return true }
            }
            guard attributes.colorMode == "color_temp", let actual = attributes.kelvin,
                  LampSettings.kelvinRange.contains(actual) else {
                return false
            }
            return abs(actual - kelvin) <= 35
        }
    }
}
